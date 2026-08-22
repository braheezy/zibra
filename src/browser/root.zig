//! Process-wide browser controller, event loop, and rendering coordinator.
//!
//! `Browser` owns one native window's tabs, chrome, z2d resources, and
//! committed render snapshot. Session/network state may be shared by a
//! process-level `BrowserApp`; screenshot mode can still own a standalone
//! session and render only to software surfaces.

const std = @import("std");
const Mutex = @import("../runtime/sync.zig").Mutex;
const sdl2 = @import("sdl");
const z2d = @import("z2d");
const compositor = z2d.compositor;
const zigimg = @import("zigimg");

const font = @import("render/font.zig");
const Glyph = font.Glyph;
const url_module = @import("../network/url.zig");
const Url = url_module.Url;
const Layout = @import("render/layout.zig");
const parser = @import("../document/parser.zig");
const HTMLParser = parser.HTMLParser;
const Node = parser.Node;
const ImageData = parser.ImageData;
const CSSParser = @import("../document/css_parser.zig").CSSParser;
const js_module = @import("../script/js.zig");
const tab_module = @import("tab.zig");
const Tab = tab_module.Tab;
const Frame = tab_module.Frame;
const ClickButton = tab_module.ClickButton;
const HistoryDirection = tab_module.HistoryDirection;
const HistoryNavigation = tab_module.HistoryNavigation;
const BrowserSession = @import("session_state.zig").BrowserSession;
const scroll_model = @import("scroll.zig");
const Chrome = @import("chrome.zig");
const task_module = @import("../runtime/task.zig");
const Task = task_module.Task;
const MeasureTime = @import("../runtime/measure_time.zig").MeasureTime;

// Default browser stylesheet - defines default styling for HTML elements
const DEFAULT_STYLE_SHEET = @embedFile("browser.css");
const default_window_title: [:0]const u8 = "zibra";

// *********************************************************
// * App Settings
// *********************************************************
const initial_window_width = 800;
const initial_window_height = 600;
pub const decodeUtf8Replace = url_module.decodeUtf8Replace;

fn showPostResubmissionDialog(window: sdl2.Window) bool {
    const cancel_label: [:0]const u8 = "Cancel";
    const resubmit_label: [:0]const u8 = "Resubmit";
    const title: [:0]const u8 = "Confirm form resubmission";
    const message: [:0]const u8 =
        "To display this page, Zibra must resend data that was previously submitted.\n" ++
        "Resubmit the form?";
    const buttons = [_]sdl2.c.SDL_MessageBoxButtonData{
        .{
            .flags = @intCast(sdl2.c.SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT),
            .buttonid = 0,
            .text = cancel_label.ptr,
        },
        .{
            .flags = @intCast(sdl2.c.SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT),
            .buttonid = 1,
            .text = resubmit_label.ptr,
        },
    };
    const data = sdl2.c.SDL_MessageBoxData{
        .flags = @intCast(sdl2.c.SDL_MESSAGEBOX_WARNING),
        .window = window.ptr,
        .title = title.ptr,
        .message = message.ptr,
        .numbuttons = @intCast(buttons.len),
        .buttons = &buttons[0],
        .colorScheme = null,
    };
    var button_id: c_int = -1;
    if (sdl2.c.SDL_ShowMessageBox(&data, &button_id) != 0) {
        std.log.warn("Failed to show POST resubmission dialog", .{});
        return false;
    }
    return button_id == 1;
}

/// A document-navigation response plus explicit ownership for its body and
/// CSP header. Generated browser pages and fetched resources share this
/// contract, so callers never infer ownership from the URL scheme.
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

pub fn navigationSecurity(url: ?*const Url, certificate_error: bool) NavigationSecurity {
    if (certificate_error) return .certificate_error;
    const current = url orelse return .none;
    return if (std.ascii.eqlIgnoreCase(current.scheme, "https")) .secure else .none;
}

fn appendWarningHtmlEscaped(
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

/// Build a self-contained warning document without incorporating bytes from
/// the untrusted peer. There is deliberately no proceed-anyway action.
pub fn certificateWarningHtml(
    allocator: std.mem.Allocator,
    requested_url: *const Url,
    certificate_error: anyerror,
) ![]u8 {
    const target = try requested_url.*.toOwnedString(allocator);
    defer allocator.free(target);

    var html = std.ArrayList(u8).empty;
    errdefer html.deinit(allocator);
    try html.appendSlice(
        allocator,
        "<html><head><title>Certificate error</title></head>" ++
            "<body><h1>Certificate error</h1>" ++
            "<p>Zibra could not verify the security certificate for <strong>",
    );
    try appendWarningHtmlEscaped(allocator, &html, target);
    try html.appendSlice(
        allocator,
        "</strong>.</p><p>The connection was stopped before any page data was loaded.</p>" ++
            "<p>Error: <code>",
    );
    try appendWarningHtmlEscaped(allocator, &html, @errorName(certificate_error));
    try html.appendSlice(allocator, "</code></p></body></html>");
    return html.toOwnedSlice(allocator);
}

fn createBrokenImage(allocator: std.mem.Allocator) !zigimg.Image {
    const width: usize = 16;
    const height: usize = 16;
    const pixel_count = width * height;
    var pixels = try allocator.alloc(u8, pixel_count * 4);
    errdefer allocator.free(pixels);

    var idx: usize = 0;
    for (0..height) |y| {
        for (0..width) |x| {
            const is_cross = x == y or x + y == width - 1;
            const r: u8 = if (is_cross) 0xCC else 0xEE;
            const g: u8 = if (is_cross) 0x33 else 0xEE;
            const b: u8 = if (is_cross) 0x33 else 0xEE;
            pixels[idx] = r;
            pixels[idx + 1] = g;
            pixels[idx + 2] = b;
            pixels[idx + 3] = 0xFF;
            idx += 4;
        }
    }

    return zigimg.Image.fromRawPixelsOwned(width, height, pixels, .rgba32);
}
pub const h_offset = 13;
pub const v_offset = 18;
pub const scrollbar_width = 10;
const scroll_step: i32 = 100;
const refresh_rate_ns: u64 = 33_000_000; // ~30 FPS
// *********************************************************

/// Convert SDL wheel units into Zibra's signed CSS-pixel scroll delta.
/// SDL reports natural scrolling separately, so normalize that direction here.
pub fn wheelScrollDelta(delta_y: i32, is_flipped: bool) i32 {
    const normalized_delta: i64 = if (is_flipped) -@as(i64, delta_y) else delta_y;
    const requested_scroll = -normalized_delta * @as(i64, scroll_step);
    return @intCast(std.math.clamp(
        requested_scroll,
        @as(i64, std.math.minInt(i32)),
        @as(i64, std.math.maxInt(i32)),
    ));
}

/// Chrome address editing takes precedence over a stale document focus. The
/// address bar consumes editing keys even when an operation is a boundary
/// no-op, such as Backspace at cursor zero.
pub fn shouldRouteContentEditing(
    address_bar_focused: bool,
    browser_focus: ?[]const u8,
    frame_has_focus: bool,
) bool {
    if (address_bar_focused) return false;
    if (browser_focus) |focus| return std.mem.eql(u8, focus, "content");
    return frame_has_focus;
}

/// Native and content-surface dimensions derived from an SDL resize event.
pub const ResizeGeometry = struct {
    window_width: i32,
    window_height: i32,
    tab_viewport_height: i32,
    tab_surface_height: ?i32,
};

const ResizeTargets = struct {
    root_surface: z2d.Surface,
    chrome_surface: z2d.Surface,
    tab_surface: ?z2d.Surface,
    cached_texture: sdl2.Texture,
};

/// Validate a native window size and derive the dependent tab target sizes.
pub fn resizeGeometry(
    window_width: i32,
    window_height: i32,
    chrome_height: i32,
    content_height: i32,
    zoom: f32,
    has_tab_surface: bool,
) ?ResizeGeometry {
    if (window_width <= 0 or window_height <= 0) return null;

    const viewport_delta = @as(i64, window_height) - @as(i64, chrome_height);
    const viewport_height: i32 = @intCast(std.math.clamp(
        viewport_delta,
        0,
        std.math.maxInt(i32),
    ));
    const scaled_content_height = scroll_model.scaleCssPx(content_height, zoom);

    return .{
        .window_width = window_width,
        .window_height = window_height,
        .tab_viewport_height = viewport_height,
        .tab_surface_height = if (has_tab_surface)
            scroll_model.interestSurfaceHeight(
                scaled_content_height,
                viewport_height,
                window_height,
            )
        else
            null,
    };
}

const WindowPos = struct {
    x: c_int,
    y: c_int,
};

fn windowPositionForFocusedDisplay() ?WindowPos {
    var mouse_x: c_int = 0;
    var mouse_y: c_int = 0;
    _ = sdl2.c.SDL_GetGlobalMouseState(&mouse_x, &mouse_y);

    const display_count = sdl2.c.SDL_GetNumVideoDisplays();
    if (display_count <= 0) return null;

    var display_index: c_int = 0;
    while (display_index < display_count) : (display_index += 1) {
        var bounds: sdl2.c.SDL_Rect = undefined;
        if (sdl2.c.SDL_GetDisplayBounds(display_index, &bounds) != 0) continue;

        if (mouse_x >= bounds.x and mouse_x < bounds.x + bounds.w and
            mouse_y >= bounds.y and mouse_y < bounds.y + bounds.h)
        {
            const centered_x = bounds.x + @divTrunc(bounds.w - @as(c_int, initial_window_width), 2);
            const centered_y = bounds.y + @divTrunc(bounds.h - @as(c_int, initial_window_height), 2);
            return .{ .x = centered_x, .y = centered_y };
        }
    }

    return null;
}

pub const AccessibilitySettings = struct {
    zoom: f32 = 1.0,
    prefers_dark: bool = false,
    screen_reader: bool = false,
    reduce_motion: bool = false,
    dark_palette: ?DarkPalette = null,
};

// Display items are the drawing commands emitted by layout.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn toZ2dRgba(self: Color) z2d.pixel.RGBA {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = self.a };
    }
};

const max_blur_kernel_radius: usize = 128;

fn blurKernelRadius(sigma: f64) usize {
    if (!std.math.isFinite(sigma) or sigma <= 0.0) return 0;
    return @intFromFloat(@min(@ceil(sigma * 3.0), @as(f64, @floatFromInt(max_blur_kernel_radius))));
}

fn rgbaFromWeightedSums(r: f64, g: f64, b: f64, a: f64) z2d.pixel.RGBA {
    return .{
        .r = @intFromFloat(@round(std.math.clamp(r, 0.0, 255.0))),
        .g = @intFromFloat(@round(std.math.clamp(g, 0.0, 255.0))),
        .b = @intFromFloat(@round(std.math.clamp(b, 0.0, 255.0))),
        .a = @intFromFloat(@round(std.math.clamp(a, 0.0, 255.0))),
    };
}

/// Apply a separable Gaussian blur to z2d's premultiplied RGBA pixels.
/// Sampling beyond the surface uses transparent black, matching CSS filter
/// edges when callers provide the standard three-sigma outset.
pub fn gaussianBlurPixels(
    allocator: std.mem.Allocator,
    pixels: []z2d.pixel.RGBA,
    width: usize,
    height: usize,
    sigma: f64,
) !void {
    const pixel_count = try std.math.mul(usize, width, height);
    if (pixel_count != pixels.len) return error.InvalidBlurBuffer;
    const radius = blurKernelRadius(sigma);
    if (radius == 0 or pixel_count == 0) return;

    const kernel_len = radius * 2 + 1;
    const weights = try allocator.alloc(f64, kernel_len);
    defer allocator.free(weights);
    var weight_total: f64 = 0.0;
    for (weights, 0..) |*weight, index| {
        const distance: f64 = @floatFromInt(@as(isize, @intCast(index)) - @as(isize, @intCast(radius)));
        weight.* = @exp(-(distance * distance) / (2.0 * sigma * sigma));
        weight_total += weight.*;
    }
    for (weights) |*weight| weight.* /= weight_total;

    const intermediate = try allocator.alloc(z2d.pixel.RGBA, pixel_count);
    defer allocator.free(intermediate);

    for (0..height) |y| {
        for (0..width) |x| {
            var r: f64 = 0.0;
            var g: f64 = 0.0;
            var b: f64 = 0.0;
            var a: f64 = 0.0;
            for (weights, 0..) |weight, index| {
                const sample_x = @as(isize, @intCast(x)) + @as(isize, @intCast(index)) - @as(isize, @intCast(radius));
                if (sample_x < 0 or sample_x >= @as(isize, @intCast(width))) continue;
                const sample = pixels[y * width + @as(usize, @intCast(sample_x))];
                r += @as(f64, @floatFromInt(sample.r)) * weight;
                g += @as(f64, @floatFromInt(sample.g)) * weight;
                b += @as(f64, @floatFromInt(sample.b)) * weight;
                a += @as(f64, @floatFromInt(sample.a)) * weight;
            }
            intermediate[y * width + x] = rgbaFromWeightedSums(r, g, b, a);
        }
    }

    for (0..height) |y| {
        for (0..width) |x| {
            var r: f64 = 0.0;
            var g: f64 = 0.0;
            var b: f64 = 0.0;
            var a: f64 = 0.0;
            for (weights, 0..) |weight, index| {
                const sample_y = @as(isize, @intCast(y)) + @as(isize, @intCast(index)) - @as(isize, @intCast(radius));
                if (sample_y < 0 or sample_y >= @as(isize, @intCast(height))) continue;
                const sample = intermediate[@as(usize, @intCast(sample_y)) * width + x];
                r += @as(f64, @floatFromInt(sample.r)) * weight;
                g += @as(f64, @floatFromInt(sample.g)) * weight;
                b += @as(f64, @floatFromInt(sample.b)) * weight;
                a += @as(f64, @floatFromInt(sample.a)) * weight;
            }
            pixels[y * width + x] = rgbaFromWeightedSums(r, g, b, a);
        }
    }
}

test "Gaussian blur spreads premultiplied color without transparent halos" {
    var pixels = [_]z2d.pixel.RGBA{.{ .r = 0, .g = 0, .b = 0, .a = 0 }} ** 49;
    pixels[3 * 7 + 3] = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    try gaussianBlurPixels(std.testing.allocator, &pixels, 7, 7, 1.0);

    const center = pixels[3 * 7 + 3];
    const neighbor = pixels[3 * 7 + 2];
    const two_away = pixels[3 * 7 + 1];
    try std.testing.expect(center.a < 255 and center.a > neighbor.a);
    try std.testing.expect(neighbor.a > 0);
    try std.testing.expect(two_away.a > 0);
    for (pixels) |pixel| {
        try std.testing.expectEqual(pixel.a, pixel.r);
        try std.testing.expectEqual(@as(u8, 0), pixel.g);
        try std.testing.expectEqual(@as(u8, 0), pixel.b);
    }
}

fn glyphSourcePixel(
    pixel_mode: font.GlyphPixelMode,
    bitmap_pixel: []const u8,
    text_color: Color,
) ?z2d.pixel.RGBA {
    std.debug.assert(bitmap_pixel.len == 4);
    const bitmap_alpha = bitmap_pixel[3];
    const final_alpha: u8 = @intCast(
        (@as(u16, bitmap_alpha) * @as(u16, text_color.a) + 127) / 255,
    );
    if (final_alpha == 0) return null;

    const source_rgb = switch (pixel_mode) {
        .alpha_mask => .{ text_color.r, text_color.g, text_color.b },
        .color => .{ bitmap_pixel[0], bitmap_pixel[1], bitmap_pixel[2] },
    };
    return (z2d.pixel.RGBA{
        .r = source_rgb[0],
        .g = source_rgb[1],
        .b = source_rgb[2],
        .a = final_alpha,
    }).multiply();
}

test "glyph source pixels tint masks but preserve color bitmaps" {
    const bitmap = [_]u8{ 210, 120, 30, 255 };
    const text_color = Color{ .r = 12, .g = 34, .b = 56, .a = 255 };

    try std.testing.expectEqual(
        z2d.pixel.RGBA{ .r = 12, .g = 34, .b = 56, .a = 255 },
        glyphSourcePixel(.alpha_mask, &bitmap, text_color).?,
    );
    try std.testing.expectEqual(
        z2d.pixel.RGBA{ .r = 210, .g = 120, .b = 30, .a = 255 },
        glyphSourcePixel(.color, &bitmap, text_color).?,
    );
}

test "glyph source pixels combine bitmap and CSS alpha" {
    const bitmap = [_]u8{ 255, 128, 64, 128 };
    const source = glyphSourcePixel(
        .color,
        &bitmap,
        .{ .r = 1, .g = 2, .b = 3, .a = 128 },
    ).?;
    try std.testing.expectEqual(@as(u8, 64), source.a);
    try std.testing.expect(source.r <= source.a);
    try std.testing.expect(source.g <= source.a);
    try std.testing.expect(source.b <= source.a);
}

pub const DarkPalette = struct {
    background: Color = .{ .r = 18, .g = 18, .b = 18, .a = 255 },
    text: Color = .{ .r = 230, .g = 230, .b = 230, .a = 255 },
    control_background: Color = .{ .r = 35, .g = 35, .b = 35, .a = 255 },
    control_text: Color = .{ .r = 230, .g = 230, .b = 230, .a = 255 },
};

// Rectangle helper for layout bounds
pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn containsPoint(self: Rect, x: i32, y: i32) bool {
        return x >= self.left and x < self.right and
            y >= self.top and y < self.bottom;
    }

    pub fn width(self: Rect) i32 {
        if (self.right <= self.left) return 0;
        return self.right - self.left;
    }

    pub fn height(self: Rect) i32 {
        if (self.bottom <= self.top) return 0;
        return self.bottom - self.top;
    }

    /// Expand bounds by the given amount in all directions
    pub fn outset(self: Rect, amount: i32) Rect {
        return .{
            .left = self.left - amount,
            .top = self.top - amount,
            .right = self.right + amount,
            .bottom = self.bottom + amount,
        };
    }

    /// Contract bounds by the given amount in all directions
    pub fn inset(self: Rect, amount: i32) Rect {
        return .{
            .left = self.left + amount,
            .top = self.top + amount,
            .right = self.right - amount,
            .bottom = self.bottom - amount,
        };
    }
};

/// A composited layer stores display items that can be rasterized once and reused.
/// Layers are created for elements with visual effects like opacity or blend modes.
pub const CompositedLayer = struct {
    /// The display items to rasterize into this layer
    display_items: []DisplayItem,
    /// Cached raster surface (null until first rasterized)
    surface: ?z2d.Surface = null,
    /// Bounds of the layer in document coordinates (with 1px outset for edge artifacts)
    bounds: Rect,
    /// Whether this layer needs to be re-rasterized
    needs_raster: bool = true,
    /// Opacity to apply when compositing this layer
    opacity: f64 = 1.0,
    /// Blend mode to apply when compositing
    blend_mode: ?[]const u8 = null,
    /// DOM node pointer for identifying this layer across frames
    node: ?*anyopaque = null,

    pub fn init(display_items: []DisplayItem, bounds: Rect, opacity: f64, blend_mode: ?[]const u8, node: ?*anyopaque) CompositedLayer {
        // Add 1px outset to avoid raster edge artifacts
        return .{
            .display_items = display_items,
            .bounds = bounds.outset(1),
            .opacity = opacity,
            .blend_mode = blend_mode,
            .node = node,
        };
    }

    pub fn deinit(self: *CompositedLayer, allocator: std.mem.Allocator) void {
        if (self.surface) |*surface| {
            surface.deinit(allocator);
            self.surface = null;
        }
        if (self.display_items.len > 0) {
            DisplayItem.freeList(allocator, self.display_items);
            self.display_items = &.{};
        }
    }

    /// Apply an opacity animation to this layer. A layer whose own node is the
    /// target can change its composite alpha without rerasterizing; a target
    /// nested in flattened/iframe-owned display items requires new pixels.
    pub fn applyCompositedOpacity(self: *CompositedLayer, node: *anyopaque, opacity: f64) bool {
        if (self.node == node) {
            self.opacity = opacity;
            return false;
        }
        if (DisplayItem.applyCompositedOpacity(self.display_items, node, opacity)) {
            self.needs_raster = true;
            return true;
        }
        return false;
    }

    /// Check if another layer can be merged into this one.
    /// Layers can merge if they have identical visual-effect ancestry (same opacity and blend_mode).
    pub fn canMerge(self: *const CompositedLayer, other_opacity: f64, other_blend_mode: ?[]const u8) bool {
        // Must have same opacity
        if (self.opacity != other_opacity) return false;

        // dst_in masks should never merge because they clip different content.
        if (self.blend_mode) |mode| {
            if (std.mem.eql(u8, mode, "dst_in")) return false;
        }

        // Must have same blend mode
        if (self.blend_mode == null and other_blend_mode == null) return true;
        if (self.blend_mode == null or other_blend_mode == null) return false;
        return std.mem.eql(u8, self.blend_mode.?, other_blend_mode.?);
    }

    /// Add display items to this layer, expanding bounds as needed.
    /// Returns true if items were added, false if incompatible.
    pub fn add(self: *CompositedLayer, allocator: std.mem.Allocator, items: []DisplayItem, item_bounds: Rect) !void {
        // Expand bounds to include new items (remove 1px outset, expand, re-add)
        const inner_bounds = self.bounds.inset(1);
        const new_bounds = Rect{
            .left = @min(inner_bounds.left, item_bounds.left),
            .top = @min(inner_bounds.top, item_bounds.top),
            .right = @max(inner_bounds.right, item_bounds.right),
            .bottom = @max(inner_bounds.bottom, item_bounds.bottom),
        };

        // Combine display items
        const old_items = self.display_items;
        const new_items = try allocator.alloc(DisplayItem, old_items.len + items.len);
        @memcpy(new_items[0..old_items.len], old_items);
        @memcpy(new_items[old_items.len..], items);

        // Publish the expanded layer only after the fallible allocation. On
        // failure, both the layer and the caller-owned incoming list remain
        // unchanged.
        self.display_items = new_items;
        self.bounds = new_bounds.outset(1);
        if (old_items.len > 0) {
            allocator.free(old_items);
        }
        if (items.len > 0) {
            allocator.free(items);
        }

        // Mark for re-rasterization since content changed
        self.needs_raster = true;
    }

    /// Rasterize the layer's display items to its cached surface
    pub fn raster(self: *CompositedLayer, allocator: std.mem.Allocator, browser: *Browser) anyerror!void {
        if (!self.needs_raster and self.surface != null) return;

        const layer_width: i32 = @max(1, self.bounds.width());
        const layer_height: i32 = @max(1, self.bounds.height());

        // Create or recreate surface if needed
        if (self.surface) |*existing| {
            if (existing.getWidth() != layer_width or existing.getHeight() != layer_height) {
                existing.deinit(allocator);
                self.surface = null;
            }
        }

        if (self.surface == null) {
            self.surface = try z2d.Surface.init(.image_surface_rgba, allocator, layer_width, layer_height);
        }

        var ctx = z2d.Context.init(browser.io, allocator, &self.surface.?);
        defer ctx.deinit();

        // Clear to transparent
        ctx.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 } } } });
        try ctx.moveTo(0, 0);
        try ctx.lineTo(@floatFromInt(layer_width), 0);
        try ctx.lineTo(@floatFromInt(layer_width), @floatFromInt(layer_height));
        try ctx.lineTo(0, @floatFromInt(layer_height));
        try ctx.closePath();
        try ctx.fill();

        // Draw display items offset by layer bounds (absolute to local mapping)
        // Items are stored in absolute coordinates, so we offset by bounds origin to draw in layer space
        const zoom = if (browser.active_tab_zoom > 0) browser.active_tab_zoom else 1.0;
        for (self.display_items) |item| {
            try browser.drawDisplayItemZ2dContextForLayer(&ctx, item, self.bounds.left, self.bounds.top, zoom);
        }

        self.needs_raster = false;
    }
};

pub const ImageDisplayItem = struct {
    x1: i32,
    y1: i32,
    x2: i32,
    y2: i32,
    source_width: i32,
    source_height: i32,
    pixels: []const u8,
    opacity: f64 = 1.0,
    source: ?DisplayItemSource = null,
};

/// Synchronous-only provenance for an uncomposed frame display item. Both
/// pointers borrow the frame's current layout/DOM generation and must be
/// cleared before the item crosses the tab-to-browser commit boundary.
pub const DisplayItemSource = struct {
    layout: *const anyopaque,
    node: ?*Node,
    /// Typed by the layout emitter. This keeps the erased layout pointer
    /// useful without making DisplayItem depend on every concrete layout type.
    layout_node_resolver: ?*const fn (*const anyopaque, ?*Node) ?*Node = null,

    /// Ask the generating layout object to validate the precise fragment node
    /// (needed for anonymous inline blocks), or to provide its own DOM node.
    pub fn originatingNode(self: DisplayItemSource) ?*Node {
        return if (self.layout_node_resolver) |resolve|
            resolve(self.layout, self.node)
        else
            self.node;
    }
};

pub const RoundedHitClip = struct {
    x1: i32,
    y1: i32,
    x2: i32,
    y2: i32,
    radius: f64,
};

pub const DisplayItem = union(enum) {
    glyph: struct {
        x: i32,
        y: i32,
        glyph: Glyph,
        color: Color,
        source: ?DisplayItemSource = null,
    },
    rect: struct {
        x1: i32,
        y1: i32,
        x2: i32,
        y2: i32,
        color: Color,
        source: ?DisplayItemSource = null,
    },
    image: ImageDisplayItem,
    iframe: struct {
        rect: Rect,
        node: *Node,
        source: ?DisplayItemSource = null,
    },
    rounded_rect: struct {
        x1: i32,
        y1: i32,
        x2: i32,
        y2: i32,
        radius: f64,
        color: Color,
        source: ?DisplayItemSource = null,
    },
    line: struct {
        x1: i32,
        y1: i32,
        x2: i32,
        y2: i32,
        color: Color,
        thickness: i32,
        source: ?DisplayItemSource = null,
    },
    outline: struct {
        rect: Rect,
        color: Color,
        thickness: i32,
        source: ?DisplayItemSource = null,
    },
    blend: struct {
        opacity: f64,
        blend_mode: ?[]const u8,
        /// CSS blur standard deviation in layout pixels. A positive value
        /// filters the complete child subtree before outer clip/opacity work.
        blur_radius: f64 = 0.0,
        /// Optional non-painting clip for this group's click geometry.
        hit_clip: ?RoundedHitClip = null,
        children: []DisplayItem,
        node: ?*anyopaque = null, // Reference back to the DOM node that created this effect
        parent: ?*const DisplayItem = null, // Parent blend for walking up the tree
        needs_compositing: bool = false, // True if this blend or descendants require composited layers
        source: ?DisplayItemSource = null,
    },
    /// Draw a pre-rasterized composited layer
    draw_composited_layer: struct {
        layer: *CompositedLayer,
        source: ?DisplayItemSource = null,
    },
    /// Apply a 2D translation transform to children
    transform: struct {
        translate_x: i32,
        translate_y: i32,
        children: []DisplayItem,
        node: ?*anyopaque = null,
        source: ?DisplayItemSource = null,
    },

    pub const HitResult = struct {
        item: *const DisplayItem,
        source: DisplayItemSource,
        /// Point in the hit primitive's local, unzoomed layout coordinates.
        x: i32,
        y: i32,
        /// Exact point in the primitive's local device coordinates.
        device_x: i32,
        device_y: i32,
    };

    pub fn source(self: *const DisplayItem) ?DisplayItemSource {
        return switch (self.*) {
            inline else => |payload| payload.source,
        };
    }

    /// Strip borrowed layout/DOM provenance before transferring a list to a
    /// longer-lived browser render snapshot.
    pub fn clearSources(items: []DisplayItem) void {
        for (items) |*item| {
            switch (item.*) {
                .blend => |*blend_item| {
                    blend_item.source = null;
                    clearSources(blend_item.children);
                },
                .transform => |*transform_item| {
                    transform_item.source = null;
                    clearSources(transform_item.children);
                },
                inline else => |*payload| payload.source = null,
            }
        }
    }

    /// Keep the frame's authoritative hit list synchronized with compositor-
    /// only opacity animation updates. The node identity is the live DOM
    /// element pointer stored by the layout effect wrapper.
    pub fn applyCompositedOpacity(items: []DisplayItem, node: *anyopaque, opacity: f64) bool {
        var updated = false;
        for (items) |*item| {
            switch (item.*) {
                .blend => |*blend_item| {
                    if (blend_item.node == node) {
                        blend_item.opacity = opacity;
                        updated = true;
                    }
                    if (applyCompositedOpacity(blend_item.children, node, opacity)) updated = true;
                },
                .transform => |*transform_item| {
                    if (applyCompositedOpacity(transform_item.children, node, opacity)) updated = true;
                },
                else => {},
            }
        }
        return updated;
    }

    pub fn scaleLayoutPx(value: i32, zoom_value: f32) i32 {
        const zoom = if (zoom_value > 0) zoom_value else 1.0;
        if (zoom == 1.0) return value;
        return @intFromFloat(@as(f32, @floatFromInt(value)) * zoom);
    }

    fn deviceToLayoutPx(value: i32, zoom_value: f32) i32 {
        const zoom = if (zoom_value > 0) zoom_value else 1.0;
        if (zoom == 1.0) return value;
        return @intFromFloat(@as(f32, @floatFromInt(value)) / zoom);
    }

    /// Convenience entry point for tests and synchronous layout-coordinate
    /// callers. Native input should retain its exact device coordinate and use
    /// hitTestDevice so fractional zoom never loses an edge pixel.
    pub fn hitTest(items: []const DisplayItem, x: i32, y: i32, zoom_value: f32) ?HitResult {
        return hitTestDevice(
            items,
            scaleLayoutPx(x, zoom_value),
            scaleLayoutPx(y, zoom_value),
            zoom_value,
        );
    }

    /// Return the topmost painted item carrying synchronous frame provenance.
    /// CSS coordinates and translations use the same truncating scale rule as
    /// raster; glyph w/h are already exact device bitmap dimensions.
    pub fn hitTestDevice(items: []const DisplayItem, x: i32, y: i32, zoom_value: f32) ?HitResult {
        const zoom = if (zoom_value > 0) zoom_value else 1.0;
        return hitTestDeviceList(items, x, y, zoom);
    }

    fn hitTestDeviceList(items: []const DisplayItem, x: i32, y: i32, zoom: f32) ?HitResult {
        var index = items.len;
        while (index > 0) {
            index -= 1;
            const item = &items[index];
            switch (item.*) {
                .blend => |blend_item| {
                    if (blend_item.opacity <= 0) continue;
                    if (blend_item.hit_clip) |clip| {
                        if (!pointInRoundedRect(x, y, clip, zoom)) continue;
                    }
                    const is_dst_in = if (blend_item.blend_mode) |mode|
                        std.mem.eql(u8, mode, "dst_in")
                    else
                        false;
                    if (is_dst_in) {
                        if (blend_item.children.len == 1) {
                            // Layout clipping is encoded as a one-child
                            // dst_in mask following the sibling content it
                            // clips. The mask is an operator, not a target.
                            if (!containsPaintedPoint(&blend_item.children[0], x, y, zoom)) return null;
                            continue;
                        }
                        if (blend_item.children.len < 2) continue;
                        const mask = &blend_item.children[blend_item.children.len - 1];
                        if (!containsPaintedPoint(mask, x, y, zoom)) continue;
                        if (hitTestDeviceList(blend_item.children[0 .. blend_item.children.len - 1], x, y, zoom)) |hit| {
                            return hit;
                        }
                        continue;
                    }
                    if (hitTestDeviceList(blend_item.children, x, y, zoom)) |hit| return hit;
                },
                .transform => |transform_item| {
                    const local_x = x - scaleLayoutPx(transform_item.translate_x, zoom);
                    const local_y = y - scaleLayoutPx(transform_item.translate_y, zoom);
                    if (hitTestDeviceList(transform_item.children, local_x, local_y, zoom)) |hit| return hit;
                },
                else => {
                    const item_source = item.source() orelse continue;
                    if (containsPrimitivePoint(item, x, y, zoom)) {
                        return .{
                            .item = item,
                            .source = item_source,
                            .x = deviceToLayoutPx(x, zoom),
                            .y = deviceToLayoutPx(y, zoom),
                            .device_x = x,
                            .device_y = y,
                        };
                    }
                },
            }
        }
        return null;
    }

    fn containsPaintedPoint(item: *const DisplayItem, x: i32, y: i32, zoom: f32) bool {
        return switch (item.*) {
            .blend => |blend_item| blk: {
                if (blend_item.opacity <= 0) break :blk false;
                if (blend_item.hit_clip) |clip| {
                    if (!pointInRoundedRect(x, y, clip, zoom)) break :blk false;
                }
                const is_dst_in = if (blend_item.blend_mode) |mode|
                    std.mem.eql(u8, mode, "dst_in")
                else
                    false;
                if (is_dst_in) {
                    if (blend_item.children.len == 1) {
                        break :blk containsPaintedPoint(&blend_item.children[0], x, y, zoom);
                    }
                    if (blend_item.children.len < 2) break :blk false;
                    const mask = &blend_item.children[blend_item.children.len - 1];
                    if (!containsPaintedPoint(mask, x, y, zoom)) break :blk false;
                    break :blk listContainsPaintedPoint(blend_item.children[0 .. blend_item.children.len - 1], x, y, zoom);
                }
                break :blk listContainsPaintedPoint(blend_item.children, x, y, zoom);
            },
            .transform => |transform_item| blk: {
                const local_x = x - scaleLayoutPx(transform_item.translate_x, zoom);
                const local_y = y - scaleLayoutPx(transform_item.translate_y, zoom);
                break :blk listContainsPaintedPoint(transform_item.children, local_x, local_y, zoom);
            },
            else => containsPrimitivePoint(item, x, y, zoom),
        };
    }

    fn listContainsPaintedPoint(items: []const DisplayItem, x: i32, y: i32, zoom: f32) bool {
        var index = items.len;
        while (index > 0) {
            index -= 1;
            const item = &items[index];
            if (item.* == .blend) {
                const blend_item = item.blend;
                const is_dst_in = if (blend_item.blend_mode) |mode|
                    std.mem.eql(u8, mode, "dst_in")
                else
                    false;
                if (is_dst_in and blend_item.children.len == 1) {
                    if (!containsPaintedPoint(&blend_item.children[0], x, y, zoom)) return false;
                    continue;
                }
            }
            if (containsPaintedPoint(item, x, y, zoom)) return true;
        }
        return false;
    }

    fn containsPrimitivePoint(item: *const DisplayItem, x: i32, y: i32, zoom: f32) bool {
        return switch (item.*) {
            .glyph => |glyph_item| glyph_item.color.a > 0 and pointInRect(
                x,
                y,
                scaleLayoutPx(glyph_item.x, zoom),
                scaleLayoutPx(glyph_item.y, zoom),
                scaleLayoutPx(glyph_item.x, zoom) + glyph_item.glyph.w,
                scaleLayoutPx(glyph_item.y, zoom) + glyph_item.glyph.h,
            ),
            .rect => |rect_item| rect_item.color.a > 0 and pointInScaledRect(x, y, rect_item.x1, rect_item.y1, rect_item.x2, rect_item.y2, zoom),
            .image => |image_item| image_item.opacity > 0 and pointInScaledRect(x, y, image_item.x1, image_item.y1, image_item.x2, image_item.y2, zoom),
            .iframe => |iframe_item| pointInScaledRect(x, y, iframe_item.rect.left, iframe_item.rect.top, iframe_item.rect.right, iframe_item.rect.bottom, zoom),
            .rounded_rect => |rounded_item| rounded_item.color.a > 0 and pointInRoundedRect(x, y, rounded_item, zoom),
            .line => |line_item| line_item.color.a > 0 and pointOnLine(x, y, line_item, zoom),
            .outline => |outline_item| outline_item.color.a > 0 and pointOnOutline(x, y, outline_item, zoom),
            .draw_composited_layer => |layer_item| pointInRect(
                x,
                y,
                layer_item.layer.bounds.left,
                layer_item.layer.bounds.top,
                layer_item.layer.bounds.right,
                layer_item.layer.bounds.bottom,
            ),
            .blend, .transform => false,
        };
    }

    fn pointInScaledRect(x: i32, y: i32, x1: i32, y1: i32, x2: i32, y2: i32, zoom: f32) bool {
        return pointInRect(
            x,
            y,
            scaleLayoutPx(x1, zoom),
            scaleLayoutPx(y1, zoom),
            scaleLayoutPx(x2, zoom),
            scaleLayoutPx(y2, zoom),
        );
    }

    fn pointInRect(x: i32, y: i32, x1: i32, y1: i32, x2: i32, y2: i32) bool {
        const left = @min(x1, x2);
        const right = @max(x1, x2);
        const top = @min(y1, y2);
        const bottom = @max(y1, y2);
        return x >= left and x < right and y >= top and y < bottom;
    }

    fn pointInRoundedRect(x: i32, y: i32, item: anytype, zoom: f32) bool {
        const left = scaleLayoutPx(@min(item.x1, item.x2), zoom);
        const right = scaleLayoutPx(@max(item.x1, item.x2), zoom);
        const top = scaleLayoutPx(@min(item.y1, item.y2), zoom);
        const bottom = scaleLayoutPx(@max(item.y1, item.y2), zoom);
        if (!pointInRect(x, y, left, top, right, bottom)) return false;
        const width: f64 = @floatFromInt(right - left);
        const height: f64 = @floatFromInt(bottom - top);
        const radius = @min(item.radius * @as(f64, zoom), @min(width / 2.0, height / 2.0));
        if (radius <= 0.5) return true;
        const x_float: f64 = @floatFromInt(x);
        const y_float: f64 = @floatFromInt(y);
        const left_float: f64 = @floatFromInt(left);
        const right_float: f64 = @floatFromInt(right);
        const top_float: f64 = @floatFromInt(top);
        const bottom_float: f64 = @floatFromInt(bottom);
        const center_x = if (x_float < left_float + radius) left_float + radius else if (x_float >= right_float - radius) right_float - radius else x_float;
        const center_y = if (y_float < top_float + radius) top_float + radius else if (y_float >= bottom_float - radius) bottom_float - radius else y_float;
        const dx = x_float - center_x;
        const dy = y_float - center_y;
        return dx * dx + dy * dy <= radius * radius;
    }

    fn pointOnLine(x: i32, y: i32, item: anytype, zoom: f32) bool {
        const x1: f64 = @floatFromInt(scaleLayoutPx(item.x1, zoom));
        const y1: f64 = @floatFromInt(scaleLayoutPx(item.y1, zoom));
        const x2: f64 = @floatFromInt(scaleLayoutPx(item.x2, zoom));
        const y2: f64 = @floatFromInt(scaleLayoutPx(item.y2, zoom));
        const dx = x2 - x1;
        const dy = y2 - y1;
        const length_squared = dx * dx + dy * dy;
        const x_float: f64 = @floatFromInt(x);
        const y_float: f64 = @floatFromInt(y);
        const t = if (length_squared == 0) 0.0 else std.math.clamp(((x_float - x1) * dx + (y_float - y1) * dy) / length_squared, 0.0, 1.0);
        const nearest_x = x1 + t * dx;
        const nearest_y = y1 + t * dy;
        const half_width = @as(f64, @floatFromInt(@max(1, scaleLayoutPx(item.thickness, zoom)))) / 2.0;
        const distance_x = x_float - nearest_x;
        const distance_y = y_float - nearest_y;
        return distance_x * distance_x + distance_y * distance_y <= half_width * half_width;
    }

    fn pointOnOutline(x: i32, y: i32, item: anytype, zoom: f32) bool {
        const left = scaleLayoutPx(@min(item.rect.left, item.rect.right), zoom);
        const right = scaleLayoutPx(@max(item.rect.left, item.rect.right), zoom);
        const top = scaleLayoutPx(@min(item.rect.top, item.rect.bottom), zoom);
        const bottom = scaleLayoutPx(@max(item.rect.top, item.rect.bottom), zoom);
        const thickness = @max(1, scaleLayoutPx(item.thickness, zoom));
        if (!pointInRect(x, y, left - thickness, top - thickness, right + thickness, bottom + thickness)) return false;
        const inner_left = left + thickness;
        const inner_right = right - thickness;
        const inner_top = top + thickness;
        const inner_bottom = bottom - thickness;
        return inner_left >= inner_right or inner_top >= inner_bottom or
            !pointInRect(x, y, inner_left, inner_top, inner_right, inner_bottom);
    }

    // Set parent pointers recursively on a display list
    // This should be called after the display list is constructed
    pub fn setParentPointers(items: []DisplayItem, parent: ?*const DisplayItem) void {
        for (items) |*item| {
            switch (item.*) {
                .blend => |*b| {
                    b.parent = parent;
                    // Recursively set parent pointers on children
                    setParentPointers(b.children, item);
                },
                else => {}, // Leaf nodes don't have parent pointers
            }
        }
    }

    pub fn freeList(allocator: std.mem.Allocator, items: []DisplayItem) void {
        for (items) |item| {
            freeItem(allocator, item);
        }
        allocator.free(items);
    }

    pub fn freeItems(allocator: std.mem.Allocator, items: []DisplayItem) void {
        for (items) |item| {
            freeItem(allocator, item);
        }
    }

    fn freeItem(allocator: std.mem.Allocator, item: DisplayItem) void {
        switch (item) {
            .blend => |b| {
                if (b.blend_mode) |mode| {
                    allocator.free(mode);
                }
                freeList(allocator, b.children);
            },
            .transform => |t| {
                freeList(allocator, t.children);
            },
            else => {},
        }
    }
};

pub const JsRenderContext = struct {
    browser_ptr: ?*anyopaque = null,
    tab_ptr: ?*anyopaque = null,
    js_context: ?*js_module = null,
    window_id: u32 = 0,
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn setPointers(
        self: *JsRenderContext,
        browser_ptr: ?*anyopaque,
        tab_ptr: ?*anyopaque,
        js_context: ?*js_module,
        window_id: u32,
    ) void {
        self.browser_ptr = browser_ptr;
        self.tab_ptr = tab_ptr;
        self.js_context = js_context;
        self.window_id = window_id;
    }

    pub fn setGeneration(self: *JsRenderContext, generation: u64) void {
        self.generation.store(generation, .seq_cst);
    }

    pub fn currentGeneration(self: *const JsRenderContext) u64 {
        return self.generation.load(.seq_cst);
    }

    pub fn matchesGeneration(self: *const JsRenderContext, expected: u64) bool {
        return self.currentGeneration() == expected;
    }
};

/// Copyable identity for one installed document. Detached helpers carry this
/// value instead of borrowing a Frame or its synchronous JS callback context.
const DocumentHandle = struct {
    window_id: u32,
    generation: u64,

    fn fromFrame(frame: *const Frame) DocumentHandle {
        return .{
            .window_id = frame.window_id,
            .generation = frame.document_generation,
        };
    }

    /// Resolve only on the serialized tab worker.
    fn resolve(self: DocumentHandle, tab: *Tab) ?*Frame {
        const frame = tab.frameForWindowId(self.window_id) orelse return null;
        if (frame.document_generation != self.generation) return null;
        return frame;
    }
};

const PendingPostResubmission = struct {
    tab: *Tab,
    target: usize,
    history_generation: u64,
};

// Browser manages the window and tabs
pub const Browser = struct {
    // Memory allocator for the browser
    allocator: std.mem.Allocator,
    io: std.Io,
    // Process/session navigation state has its own lock so BrowserApp can share
    // this pointer without borrowing one window's render lock.
    session_state: *BrowserSession,
    owns_sdl: bool,
    owns_text_input: bool,
    owns_session: bool,
    owns_measure: bool,
    // Interactive presentation resources. Screenshot mode leaves these null
    // and exports the software root surface directly.
    window: ?sdl2.Window,
    canvas: ?sdl2.Renderer,
    // z2d surface for drawing (RGBA format like the tutorial)
    root_surface: z2d.Surface,
    // z2d context for drawing operations
    context: z2d.Context,
    // Separate surface for browser chrome (UI)
    chrome_surface: z2d.Surface,
    // Bounded cache for the current tab's device-pixel interest region.
    tab_surface: ?z2d.Surface,
    tab_interest_region: scroll_model.InterestRegion = .{ .start_px = 0, .height_px = 0 },
    tab_interest_region_valid: bool = false,
    // Window dimensions
    window_width: i32 = initial_window_width,
    window_height: i32 = initial_window_height,
    layout_engine: *Layout,
    // Default browser stylesheet rules
    default_style_sheet_rules: []CSSParser.CSSRule,
    // List of tabs
    tabs: std.ArrayList(*Tab),
    // Owned link targets requested by tab workers. The browser thread drains
    // this queue because it exclusively creates tabs and updates chrome.
    pending_new_tabs: std.ArrayList(Url),
    // A tab worker publishes only stable tab identity plus history indexes.
    // The native confirmation dialog is consumed on the SDL/UI thread.
    pending_post_resubmission: ?PendingPostResubmission = null,
    post_resubmission_dialog_active: bool = false,
    // Index of the active tab
    active_tab_index: ?usize = null,
    // Set by tab workers under `lock`; consumed by the interactive main loop.
    window_title_dirty: bool = true,
    // Browser chrome (UI)
    chrome: Chrome = undefined,
    // Focus tracking: null means nothing focused, "content" means page content
    focus: ?[]const u8 = null,
    animation_timer_active: bool = false,
    needs_composite: bool = true,
    needs_raster: bool = true,
    needs_draw: bool = true,
    needs_animation_frame: bool = false,
    shutting_down: bool = false,
    resize_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    // Heap-stable because every tab worker and every App window shares it.
    measure: *MeasureTime,
    lock: Mutex,
    // Optimistic address-bar text may lead a pending load. Bookmark state uses
    // the separately owned URL from the latest committed document.
    active_tab_url: ?[]u8 = null,
    active_tab_committed_url: ?[]u8 = null,
    active_tab_committed_security: NavigationSecurity = .none,
    active_tab_scroll: i32 = 0,
    active_tab_height: i32 = 0,
    active_tab_zoom: f32 = 1.0,
    active_tab_prefers_dark: bool = false,
    active_tab_display_list: ?[]DisplayItem = null,
    // Composited layers for caching rasterized content
    composited_layers: std.ArrayList(CompositedLayer),
    // Draw list created from composite phase
    tab_draw_list: std.ArrayList(DisplayItem),
    // Cached SDL texture for GPU-accelerated rendering
    cached_texture: ?sdl2.Texture = null,
    // Debug flag to visualize composited layer boundaries
    debug_layer_borders: bool = false,
    profiling_enabled: bool = false,

    /// Create a standalone Browser. It owns SDL and its session/measurement
    /// services; the interactive executable instead uses `initAppWindow` so
    /// one BrowserApp owns those process-level resources exactly once.
    pub fn init(
        al: std.mem.Allocator,
        io: std.Io,
        environ: *const std.process.Environ.Map,
        rtl_flag: bool,
        headless: bool,
    ) !*Browser {
        const session_state = try al.create(BrowserSession);
        errdefer al.destroy(session_state);
        session_state.* = BrowserSession.init(al, io);
        errdefer session_state.deinit();

        const measure = try al.create(MeasureTime);
        errdefer al.destroy(measure);
        measure.* = try MeasureTime.init(al, io, environ);
        errdefer measure.finish();

        try sdl2.init(.{
            .video = true,
        });
        errdefer sdl2.quit();

        if (!headless) sdl2.startTextInput();
        errdefer if (!headless) sdl2.stopTextInput();

        return initWithSharedState(
            al,
            io,
            environ,
            rtl_flag,
            headless,
            session_state,
            measure,
            .{
                .owns_sdl = true,
                .owns_text_input = !headless,
                .owns_session = true,
                .owns_measure = true,
            },
        );
    }

    /// Create one interactive Browser window borrowing process-level services
    /// from BrowserApp. SDL video and text input must already be initialized.
    pub fn initAppWindow(
        al: std.mem.Allocator,
        io: std.Io,
        environ: *const std.process.Environ.Map,
        rtl_flag: bool,
        session_state: *BrowserSession,
        measure: *MeasureTime,
    ) !*Browser {
        return initWithSharedState(
            al,
            io,
            environ,
            rtl_flag,
            false,
            session_state,
            measure,
            .{
                .owns_sdl = false,
                .owns_text_input = false,
                .owns_session = false,
                .owns_measure = false,
            },
        );
    }

    const Ownership = struct {
        owns_sdl: bool,
        owns_text_input: bool,
        owns_session: bool,
        owns_measure: bool,
    };

    fn initWithSharedState(
        al: std.mem.Allocator,
        io: std.Io,
        environ: *const std.process.Environ.Map,
        rtl_flag: bool,
        headless: bool,
        session_state: *BrowserSession,
        measure: *MeasureTime,
        ownership: Ownership,
    ) !*Browser {
        const browser = try al.create(Browser);
        errdefer al.destroy(browser);

        var screen: ?sdl2.Window = null;
        errdefer if (screen) |window| window.destroy();
        var renderer: ?sdl2.Renderer = null;
        errdefer if (renderer) |canvas| canvas.destroy();
        var cached_texture: ?sdl2.Texture = null;
        errdefer if (cached_texture) |texture| texture.destroy();

        if (!headless) {
            const preferred_position = windowPositionForFocusedDisplay();
            const window_x: sdl2.WindowPosition = if (preferred_position) |pos| .{ .absolute = pos.x } else .default;
            const window_y: sdl2.WindowPosition = if (preferred_position) |pos| .{ .absolute = pos.y } else .default;
            const window_visibility: sdl2.WindowFlags.Visibility = if (preferred_position != null) .hidden else .default;

            // Interactive mode creates the native presentation resources.
            screen = try sdl2.createWindow(
                "zibra",
                window_x,
                window_y,
                initial_window_width,
                initial_window_height,
                .{ .vis = window_visibility, .resizable = true },
            );
            if (preferred_position) |pos| {
                try screen.?.setPosition(.{ .x = pos.x, .y = pos.y });
                screen.?.setVisible(true);
            }

            renderer = try sdl2.createRenderer(
                screen.?,
                null,
                .{ .accelerated = true },
            );

            const renderer_info = try renderer.?.getInfo();
            const renderer_name = std.mem.span(renderer_info.name);
            std.log.info("SDL renderer backend: {s}", .{renderer_name});

            // Use ABGR8888 to match z2d's RGBA memory layout.
            cached_texture = try sdl2.createTexture(
                renderer.?,
                .abgr8888,
                .streaming,
                initial_window_width,
                initial_window_height,
            );
            try cached_texture.?.setBlendMode(.blend);
        } else {
            // SDL's video subsystem remains initialized because SDL_ttf needs
            // it on macOS, but no OS window, renderer, or texture is created.
            std.log.info("Screenshot renderer: software z2d (no SDL window)", .{});
        }

        // Parse the default browser stylesheet
        var css_parser = try CSSParser.init(al, DEFAULT_STYLE_SHEET, false);
        defer css_parser.deinit(al);
        const default_rules = try css_parser.parse(al);
        errdefer {
            for (default_rules) |*rule| rule.deinit(al);
            al.free(default_rules);
        }
        for (default_rules) |*rule| {
            rule.owned = false;
        }

        const layout_engine = try Layout.init(
            al,
            io,
            environ,
            initial_window_width,
            initial_window_height,
            rtl_flag,
        );
        errdefer layout_engine.deinit();

        // Create z2d surface for drawing (RGBA format like the tutorial)
        var root_surface = try z2d.Surface.init(.image_surface_rgba, al, initial_window_width, initial_window_height);
        errdefer root_surface.deinit(al);

        const profiling_enabled = isProfilingEnabled(environ);

        var chrome = try Chrome.init(
            io,
            environ,
            initial_window_width,
            al,
            rtl_flag,
        );
        errdefer chrome.deinit();
        if (screen) |window| {
            window.setMinimumSize(
                chrome.address_rect.left + chrome.padding + 1,
                chrome.bottom + 1,
            );
        }

        browser.* = Browser{
            .allocator = al,
            .io = io,
            .session_state = session_state,
            .owns_sdl = ownership.owns_sdl,
            .owns_text_input = ownership.owns_text_input,
            .owns_session = ownership.owns_session,
            .owns_measure = ownership.owns_measure,
            .window = screen,
            .canvas = renderer,
            .root_surface = root_surface,
            .context = undefined,
            .chrome_surface = undefined, // Will be set below
            .tab_surface = null,
            .layout_engine = layout_engine,
            .default_style_sheet_rules = default_rules,
            .tabs = std.ArrayList(*Tab).empty,
            .pending_new_tabs = std.ArrayList(Url).empty,
            .chrome = chrome,
            .measure = measure,
            .lock = .init(io),
            .cached_texture = cached_texture,
            .composited_layers = std.ArrayList(CompositedLayer).empty,
            .tab_draw_list = std.ArrayList(DisplayItem).empty,
            .profiling_enabled = profiling_enabled,
        };

        // z2d.Context stores the Surface pointer. Browser is heap-stable so
        // this points at the final field address rather than an init-local copy.
        browser.context = z2d.Context.init(io, al, &browser.root_surface);
        errdefer browser.context.deinit();

        // Create chrome surface (fixed height based on chrome.bottom)
        browser.chrome_surface = try z2d.Surface.init(.image_surface_rgba, al, initial_window_width, @intCast(browser.chrome.bottom));
        errdefer browser.chrome_surface.deinit(al);

        _ = browser.measure.registerThread("Browser thread") catch |err| {
            std.log.warn("Failed to register browser thread: {}", .{err});
        };

        return browser;
    }

    fn isProfilingEnabled(environ: *const std.process.Environ.Map) bool {
        const env = environ.get("ZIBRA_PROFILE") orelse return false;
        if (env.len == 0) return false;
        return !std.mem.eql(u8, env, "0");
    }

    // Get the active tab (if any)
    pub fn activeTab(self: *const Browser) ?*Tab {
        if (self.active_tab_index) |idx| {
            if (idx < self.tabs.items.len) {
                return self.tabs.items[idx];
            }
        }
        return null;
    }

    pub fn windowId(self: *const Browser) !u32 {
        const window = self.window orelse return error.BrowserHasNoNativeWindow;
        return window.getID();
    }

    /// Publish a shared-session visit to this window without holding the
    /// session lock. The active tab observes the generation on its worker.
    pub fn requestVisitedGenerationRefresh(self: *Browser) void {
        self.lock.lock();
        self.needs_animation_frame = true;
        self.lock.unlock();
        self.scheduleAnimationFrame();
    }

    /// Bookmark selection is chrome-only; rerastering is sufficient and does
    /// not require taking BrowserSession.lock while Browser.lock is held.
    pub fn requestBookmarkGenerationRefresh(self: *Browser) void {
        self.setNeedsRasterDraw();
    }

    /// Record a navigation in browser-session state. The session owns a
    /// canonical string, never this owning Url.
    pub fn markVisited(self: *Browser, url: *const Url) !bool {
        const inserted = try self.session_state.markVisited(url);
        if (!inserted) return false;

        // Existing documents may already contain a link to this URL. Publish
        // an animation request so the active tab observes the new session
        // generation; background tabs do the same when activated.
        self.lock.lock();
        self.needs_animation_frame = true;
        self.lock.unlock();
        self.scheduleAnimationFrame();
        return true;
    }

    /// Publish both sides of a successful redirected navigation, then move
    /// the final destination into the caller's owning URL slot. A navigation
    /// without a redirect naturally deduplicates its second insertion.
    pub fn recordSuccessfulNavigation(
        self: *Browser,
        requested_url: *Url,
        final_url: *?Url,
    ) !void {
        _ = try self.markVisited(requested_url);
        if (final_url.*) |resolved| {
            requested_url.*.free(self.allocator);
            requested_url.* = resolved;
            final_url.* = null;
        }
        _ = try self.markVisited(requested_url);
    }

    /// Annotate every anchor against the browser-session visited set. Each
    /// element stores only a boolean; resolved Url values remain local owners.
    pub fn annotateVisitedLinks(self: *Browser, root: *Node, base_url: *const Url) !void {
        switch (root.*) {
            .text => {},
            .element => |*element| {
                if (std.ascii.eqlIgnoreCase(element.tag, "a")) {
                    element.is_visited = false;
                    if (element.attributes) |attrs| {
                        if (attrs.get("href")) |href| {
                            const resolved = try base_url.*.resolveForNavigation(self.allocator, href);
                            defer resolved.free(self.allocator);
                            element.is_visited = try self.session_state.isVisited(&resolved);
                        }
                    }
                }
                for (element.children.items) |*child| {
                    try self.annotateVisitedLinks(child, base_url);
                }
            },
        }
    }

    /// Toggle the latest committed document URL, never an optimistic pending
    /// address. The copied canonical text keeps Browser.lock and
    /// BrowserSession.lock disjoint and prevents a concurrent commit from
    /// invalidating the session operation's input.
    pub fn toggleActiveBookmark(self: *Browser) !bool {
        const canonical = blk: {
            self.lock.lock();
            defer self.lock.unlock();
            const active_url = self.active_tab_committed_url orelse return false;
            break :blk try self.allocator.dupe(u8, active_url);
        };
        defer self.allocator.free(canonical);

        _ = try self.session_state.toggleBookmarkCanonical(canonical);
        return true;
    }

    /// Called while Browser.lock stabilizes the committed chrome URL during
    /// raster. Bookmark storage itself is synchronized by BrowserSession.
    pub fn activePageIsBookmarked(self: *const Browser) bool {
        const active_url = self.active_tab_committed_url orelse return false;
        return self.session_state.isBookmarkedCanonical(active_url);
    }

    fn activeZoom(self: *const Browser) f32 {
        return if (self.active_tab_zoom > 0) self.active_tab_zoom else 1.0;
    }

    fn scalePx(self: *const Browser, value: i32) i32 {
        const zoom = self.activeZoom();
        if (zoom == 1.0) return value;
        return @intFromFloat(@as(f32, @floatFromInt(value)) * zoom);
    }

    fn scalePxWithZoom(self: *const Browser, value: i32, zoom: f32) i32 {
        _ = self;
        if (zoom == 1.0) return value;
        return @intFromFloat(@as(f32, @floatFromInt(value)) * zoom);
    }

    fn scalePxFWithZoom(self: *const Browser, value: f64, zoom: f32) f64 {
        _ = self;
        if (zoom == 1.0) return value;
        return value * @as(f64, zoom);
    }

    fn tabViewportHeightPx(self: *const Browser) i32 {
        const viewport_i64 = @as(i64, self.window_height) - @as(i64, self.chrome.bottom);
        return @intCast(std.math.clamp(
            viewport_i64,
            0,
            @as(i64, std.math.maxInt(i32)),
        ));
    }

    /// Calculate the device-pixel cache window for one root scroll position.
    /// Browser.lock stabilizes the active document geometry at every call site.
    fn interestRegionForScroll(self: *const Browser, scroll_css: i32) scroll_model.InterestRegion {
        const zoom = self.activeZoom();
        return scroll_model.calculateInterestRegion(
            scroll_model.scaleCssPx(self.active_tab_height, zoom),
            self.tabViewportHeightPx(),
            self.window_height,
            scroll_model.scaleCssPx(scroll_css, zoom),
        );
    }

    fn interestRegionContainsScroll(self: *const Browser, scroll_css: i32) bool {
        if (!self.tab_interest_region_valid) return false;
        return self.tab_interest_region.containsViewport(
            scroll_model.scaleCssPx(scroll_css, self.activeZoom()),
            self.tabViewportHeightPx(),
        );
    }

    fn invalidateInterestRegion(self: *Browser) void {
        self.tab_interest_region_valid = false;
    }

    pub fn handleScroll(self: *Browser, delta: i32) void {
        var should_schedule = false;
        self.lock.lock();
        const tab = self.activeTab();
        if (tab) |active| {
            const target_frame = active.focused_frame orelse active.root_frame;
            if (target_frame) |frame| {
                const new_scroll = active.clampScrollForFrame(frame, frame.scroll +| delta);
                if (new_scroll != frame.scroll) {
                    frame.scroll = new_scroll;
                    if (frame == active.root_frame) {
                        self.active_tab_scroll = new_scroll;
                        // Scrolling inside the raster cache only moves the
                        // cached surface. Crossing an edge requests a new
                        // interest-region raster around the viewport.
                        if (!self.interestRegionContainsScroll(new_scroll)) {
                            self.needs_raster = true;
                        }
                    } else {
                        // We already hold Browser.lock here; publish the tab
                        // paint bit directly instead of re-entering through
                        // Tab.setNeedsPaint. The flags below schedule the same
                        // animation after the lock is released.
                        active.needs_paint = true;
                        self.needs_composite = true;
                        self.needs_raster = true;
                    }
                    self.needs_draw = true;
                    self.needs_animation_frame = true;
                    self.animation_timer_active = false;
                    should_schedule = true;
                }
            }
        }
        self.lock.unlock();
        if (should_schedule) {
            self.scheduleAnimationFrame();
        }
    }

    pub fn setActiveTab(self: *Browser, tab: *Tab) void {
        var should_schedule = false;
        self.lock.lock();
        var found_idx: ?usize = null;
        var scan_idx: usize = 0;
        while (scan_idx < self.tabs.items.len) {
            if (self.tabs.items[scan_idx] == tab) {
                found_idx = scan_idx;
                break;
            }
            scan_idx += 1;
        }
        if (found_idx) |idx| {
            self.active_tab_index = idx;
            if (self.pending_post_resubmission) |pending| {
                if (pending.tab != tab) self.pending_post_resubmission = null;
            }
            tab.requestActivationCommit();
            self.window_title_dirty = true;
            self.active_tab_scroll = 0;
            self.active_tab_zoom = tab.accessibility.zoom;
            self.active_tab_prefers_dark = tab.accessibility.prefers_dark;
            if (self.active_tab_url) |url| {
                self.allocator.free(url);
            }
            self.active_tab_url = null;
            if (self.active_tab_committed_url) |url| {
                self.allocator.free(url);
            }
            self.active_tab_committed_url = null;
            self.active_tab_committed_security = .none;

            self.retireActiveRenderStateLocked();

            // Reset all dirty flags to force full rebuild
            self.needs_composite = true;
            self.needs_raster = true;
            self.needs_draw = true;
            self.needs_animation_frame = true;
            self.animation_timer_active = false;
            should_schedule = true;
        }
        self.lock.unlock();
        if (should_schedule) {
            self.scheduleAnimationFrame();
        }
    }

    /// Replace a tab's owned root-document title. Native window mutation
    /// remains on the interactive main loop.
    pub fn updateTabTitle(self: *Browser, tab: *Tab, title: ?[:0]u8) void {
        self.lock.lock();
        defer self.lock.unlock();

        if (tab.title) |old_title| self.allocator.free(old_title);
        tab.title = title;
        if (self.activeTab() == tab) self.window_title_dirty = true;
    }

    fn applyWindowTitle(self: *Browser) void {
        const window = self.window orelse return;
        self.lock.lock();
        defer self.lock.unlock();
        if (!self.window_title_dirty) return;

        const title = if (self.activeTab()) |tab|
            tab.title orelse default_window_title
        else
            default_window_title;
        window.setTitle(title);
        self.window_title_dirty = false;
    }

    /// Retire derived draw state before the committed display list it borrows.
    /// Caller must hold `self.lock`.
    fn retireActiveRenderStateLocked(self: *Browser) void {
        self.invalidateInterestRegion();
        if (self.tab_draw_list.items.len > 0) {
            DisplayItem.freeItems(self.allocator, self.tab_draw_list.items);
            self.tab_draw_list.items.len = 0;
        }
        for (self.composited_layers.items) |*layer| {
            layer.deinit(self.allocator);
        }
        self.composited_layers.items.len = 0;
        if (self.active_tab_display_list) |display_list| {
            DisplayItem.freeList(self.allocator, display_list);
            self.active_tab_display_list = null;
        }
    }

    /// Wait for any in-progress raster/draw and release browser-side borrows of
    /// a tab before that tab retires a document generation.
    pub fn retireRenderStateForTab(self: *Browser, tab: *Tab) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.activeTab() != tab) return;
        self.retireActiveRenderStateLocked();
        self.needs_composite = true;
        self.needs_raster = true;
        self.needs_draw = true;
    }

    // Create a new tab and load a URL into it
    /// Takes ownership of `url`, including on failure.
    pub fn newTab(self: *Browser, url: Url) !void {
        var owned_url = url;
        var owns_url = true;
        defer if (owns_url) owned_url.free(self.allocator);

        const tab_height = @max(self.window_height - self.chrome.bottom, 0);
        const tab = try self.allocator.create(Tab);
        tab.* = Tab.init(self.allocator, self.window_width, tab_height, self.measure);
        var tab_adopted = false;
        errdefer if (!tab_adopted) {
            tab.deinit();
            self.allocator.destroy(tab);
        };
        tab.browser = self;
        tab.logAccessibilitySettings("init");
        // Start the task runner thread now that the Tab is in its final memory location
        try tab.start();

        try self.tabs.append(self.allocator, tab);
        tab_adopted = true;
        self.setActiveTab(tab);

        const url_ptr = try self.allocator.create(Url);
        url_ptr.* = owned_url;
        owns_url = false;
        var url_owned = true;
        defer if (url_owned) {
            url_ptr.*.free(self.allocator);
            self.allocator.destroy(url_ptr);
        };

        try self.scheduleLoad(tab, url_ptr, null);
        url_owned = false;
    }

    /// Transfer an owned URL from a tab worker to the browser thread.
    /// Ownership moves into the queue only when this function succeeds.
    pub fn queueNewTab(self: *Browser, url: Url) !void {
        self.lock.lock();
        if (self.shutting_down) {
            self.lock.unlock();
            return error.BrowserShuttingDown;
        }
        self.pending_new_tabs.ensureUnusedCapacity(self.allocator, 1) catch |err| {
            self.lock.unlock();
            return err;
        };

        // Every fallible queue step has succeeded before the visit is
        // published. Browser.lock keeps the owned Url local until it is
        // appended, while BrowserSession copies its canonical string.
        const inserted = self.session_state.markVisited(&url) catch |err| {
            self.lock.unlock();
            return err;
        };
        self.pending_new_tabs.appendAssumeCapacity(url);
        if (inserted) self.needs_animation_frame = true;
        self.lock.unlock();

        if (inserted) self.scheduleAnimationFrame();
    }

    fn openPendingTabs(self: *Browser) void {
        while (true) {
            self.lock.lock();
            if (self.pending_new_tabs.items.len == 0) {
                self.lock.unlock();
                return;
            }
            const url = self.pending_new_tabs.orderedRemove(0);
            self.lock.unlock();

            self.newTab(url) catch |err| {
                std.log.err("Failed to open queued tab: {any}", .{err});
            };
        }
    }

    const screenshot_timeout_ns: i64 = 30 * std.time.ns_per_s;

    // Run the browser event loop
    pub fn run(self: *Browser) !void {
        if (self.canvas == null or self.window == null) {
            return error.InteractiveBrowserRequiresWindow;
        }
        try self.runLoop();
    }

    /// Run the normal browser pipeline against software surfaces, write the
    /// quiescent frame to `path`, and exit without an SDL window or renderer.
    pub fn runToScreenshot(self: *Browser, path: []const u8) !void {
        if (self.canvas != null or self.window != null) {
            return error.ScreenshotRequiresHeadlessBrowser;
        }
        defer self.finishRunLoop();

        var ready_checks: u8 = 0;
        const started_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
        while (true) {
            self.scheduleAnimationFrame();

            // FontManager/SDL_ttf is shared with the tab worker. Render only
            // after all tab and detached work is quiescent so glyph state is
            // never mutated concurrently during a deterministic capture.
            if (self.isScreenshotRenderSafe()) {
                try self.compositeRasterAndDraw();
            }

            if (self.isScreenshotReady()) {
                ready_checks += 1;
                if (ready_checks >= 2) {
                    try self.writeScreenshot(path);
                    std.log.info("Screenshot written to {s}", .{path});
                    return;
                }
            } else {
                ready_checks = 0;
            }

            const elapsed_ns = std.Io.Clock.awake.now(self.io).nanoseconds - started_ns;
            if (elapsed_ns >= screenshot_timeout_ns) {
                std.log.err("Screenshot timed out after 30 seconds.", .{});
                // A detached page task may be stuck and prevent safe teardown.
                std.process.exit(124);
            }
            try self.io.sleep(.fromNanoseconds(2_000_000), .awake);
        }
    }

    fn runLoop(self: *Browser) !void {
        defer self.finishRunLoop();

        var quit = false;
        self.scheduleAnimationFrame();

        while (!quit) {
            self.openPendingTabs();
            self.processPendingPostResubmission();
            self.applyWindowTitle();

            var handled_event = false;
            // Use waitEventTimeout to be responsive to system events while still
            // limiting frame rate. This prevents the macOS beach ball by waking
            // immediately when events arrive instead of blocking in delay().
            if (sdl2.waitEventTimeout(17)) |event| {
                handled_event = true;
                if (try self.handleEvent(event)) {
                    quit = true;
                }

                // Process any additional pending events without blocking
                while (sdl2.pollEvent()) |extra_event| {
                    handled_event = true;
                    if (try self.handleEvent(extra_event)) {
                        quit = true;
                        break;
                    }
                }
            }

            if (!quit) {
                try self.compositeRasterAndDraw();
                self.scheduleAnimationFrame();

                if (!handled_event and self.isIdle()) {
                    // Yield briefly to avoid a busy loop when there's no work.
                    try self.io.sleep(.fromNanoseconds(2_000_000), .awake); // 2ms
                }
            }
        }
    }

    /// Perform one nonblocking iteration of one native window. BrowserApp is
    /// responsible for SDL polling and calls this for every registered window.
    pub fn tick(self: *Browser) !bool {
        self.openPendingTabs();
        self.processPendingPostResubmission();
        self.applyWindowTitle();
        try self.compositeRasterAndDraw();
        self.scheduleAnimationFrame();
        return self.isIdle();
    }

    fn processPendingPostResubmission(self: *Browser) void {
        self.lock.lock();
        const pending = self.pending_post_resubmission;
        self.pending_post_resubmission = null;
        const should_prompt = if (pending) |request|
            !self.shutting_down and self.activeTab() == request.tab and self.window != null
        else
            false;
        if (should_prompt) self.post_resubmission_dialog_active = true;
        self.lock.unlock();

        const request = pending orelse return;
        if (!should_prompt) return;
        const confirmed = showPostResubmissionDialog(self.window.?);

        self.lock.lock();
        self.post_resubmission_dialog_active = false;
        const still_live = !self.shutting_down and self.activeTab() == request.tab;
        self.lock.unlock();

        if (confirmed and still_live) self.scheduleConfirmedPostResubmission(request);
    }

    fn finishRunLoop(self: *Browser) void {
        self.lock.lock();
        self.shutting_down = true;
        self.needs_animation_frame = false;
        self.pending_post_resubmission = null;
        self.lock.unlock();
    }

    fn isScreenshotReady(self: *Browser) bool {
        self.lock.lock();
        const tab = self.activeTab();
        const render_ready = tab != null and
            self.active_tab_display_list != null and
            !self.needs_composite and
            !self.needs_raster and
            !self.needs_draw and
            !self.needs_animation_frame and
            !self.animation_timer_active;
        self.lock.unlock();

        if (!render_ready) return false;
        return tab.?.isQuiescent();
    }

    fn isScreenshotRenderSafe(self: *Browser) bool {
        self.lock.lock();
        const tab = self.activeTab();
        const animation_quiet = !self.needs_animation_frame and !self.animation_timer_active;
        self.lock.unlock();
        if (tab == null or !animation_quiet) return false;
        return tab.?.isQuiescent();
    }

    fn writeScreenshot(self: *Browser, path: []const u8) !void {
        try z2d.png_exporter.writeToPNGFile(self.io, self.root_surface, path, .{});
    }

    pub fn isIdle(self: *Browser) bool {
        self.lock.lock();
        defer self.lock.unlock();
        return !self.needs_composite and !self.needs_raster and !self.needs_draw and !self.needs_animation_frame;
    }

    // Handle a single SDL event. Returns true if quit was requested.
    pub fn handleEvent(self: *Browser, event: sdl2.Event) !bool {
        switch (event) {
            .quit => return true,
            .key_down => |kb_event| {
                try self.handleKeyEvent(kb_event.keycode, kb_event.modifiers);
                if (kb_event.keycode == .escape) {
                    return true;
                }
            },
            .text_input => |text_event| {
                const text = std.mem.sliceTo(&text_event.text, 0);
                var chrome_changed = false;
                for (text) |char| {
                    if (char >= 0x20 and char < 0x7f) {
                        const address_bar_focused = self.chrome.isAddressBarFocused();
                        if (try self.chrome.keypress(char)) {
                            chrome_changed = true;
                        }
                        if (self.activeTab()) |tab| {
                            const frame_focus = if (tab.root_frame) |frame| frame.focus != null else false;
                            if (shouldRouteContentEditing(
                                address_bar_focused,
                                self.focus,
                                frame_focus,
                            )) {
                                self.scheduleTabKeypressTask(tab, char);
                            }
                        }
                    }
                }
                if (chrome_changed) {
                    // Chrome-only update; avoid recomposite if the display list is unchanged.
                    self.setNeedsRasterDraw();
                }
            },
            .mouse_wheel => |wheel_event| {
                const delta = wheelScrollDelta(wheel_event.delta_y, wheel_event.direction == .flipped);
                if (delta != 0) self.handleScroll(delta);
            },
            .mouse_button_down => |button_event| {
                switch (button_event.button) {
                    .left => try self.handleClick(button_event.x, button_event.y),
                    .middle => self.handleMiddleClick(button_event.x, button_event.y),
                    else => {},
                }
            },
            .mouse_motion => |motion_event| {
                try self.handleHover(motion_event.x, motion_event.y);
            },
            .window => |window_event| {
                try self.handleWindowEvent(window_event);
            },
            else => {},
        }
        return false;
    }

    pub fn handleWindowEvent(self: *Browser, window_event: sdl2.WindowEvent) !void {
        const canvas = self.canvas orelse return;
        switch (window_event.type) {
            .resized, .size_changed => |size| {
                self.lock.lock();
                const active_tab_height = self.active_tab_height;
                const active_tab_zoom = self.activeZoom();
                self.lock.unlock();
                const geometry = resizeGeometry(
                    size.width,
                    size.height,
                    self.chrome.bottom,
                    active_tab_height,
                    active_tab_zoom,
                    self.tab_surface != null,
                ) orelse return;
                if (geometry.window_width == self.window_width and
                    geometry.window_height == self.window_height)
                {
                    return;
                }

                try canvas.setViewport(null);
                const targets = try self.createResizeTargets(geometry);
                self.installResizeTargets(targets);

                self.lock.lock();
                self.window_width = geometry.window_width;
                self.window_height = geometry.window_height;
                self.invalidateInterestRegion();
                self.needs_composite = true;
                self.needs_raster = true;
                self.needs_draw = true;
                self.lock.unlock();
                self.chrome.resizeDocument(geometry.window_width);

                const generation = self.resize_generation.fetchAdd(1, .seq_cst) +% 1;
                for (self.tabs.items) |tab| {
                    self.scheduleTabResizeTask(
                        tab,
                        geometry.window_width,
                        geometry.tab_viewport_height,
                        generation,
                    );
                }

                // Draw the previous display list at the new native size while
                // the tab worker prepares the reflowed replacement.
                self.setNeedsCompositeRasterDraw();
            },
            else => {},
        }
    }

    /// Allocate a complete replacement generation before retiring any live
    /// SDL or z2d target. An allocation failure therefore leaves the current
    /// render generation usable.
    fn createResizeTargets(self: *Browser, geometry: ResizeGeometry) !ResizeTargets {
        const canvas = self.canvas orelse return error.HeadlessBrowserCannotResize;
        var root_surface = try z2d.Surface.init(
            .image_surface_rgba,
            self.allocator,
            geometry.window_width,
            geometry.window_height,
        );
        errdefer root_surface.deinit(self.allocator);

        var chrome_surface = try z2d.Surface.init(
            .image_surface_rgba,
            self.allocator,
            geometry.window_width,
            @max(self.chrome.bottom, 1),
        );
        errdefer chrome_surface.deinit(self.allocator);

        var tab_surface: ?z2d.Surface = null;
        errdefer if (tab_surface) |*surface| surface.deinit(self.allocator);
        if (geometry.tab_surface_height) |height| {
            tab_surface = try z2d.Surface.init(
                .image_surface_rgba,
                self.allocator,
                geometry.window_width,
                height,
            );
        }

        const cached_texture = try sdl2.createTexture(
            canvas,
            .abgr8888,
            .streaming,
            @intCast(geometry.window_width),
            @intCast(geometry.window_height),
        );
        errdefer cached_texture.destroy();
        try cached_texture.setBlendMode(.blend);

        return .{
            .root_surface = root_surface,
            .chrome_surface = chrome_surface,
            .tab_surface = tab_surface,
            .cached_texture = cached_texture,
        };
    }

    fn installResizeTargets(self: *Browser, targets: ResizeTargets) void {
        self.context.deinit();
        self.root_surface.deinit(self.allocator);
        self.root_surface = targets.root_surface;
        self.context = z2d.Context.init(self.io, self.allocator, &self.root_surface);

        self.chrome_surface.deinit(self.allocator);
        self.chrome_surface = targets.chrome_surface;

        if (self.tab_surface) |*surface| surface.deinit(self.allocator);
        self.tab_surface = targets.tab_surface;

        if (self.cached_texture) |texture| texture.destroy();
        self.cached_texture = targets.cached_texture;
    }

    fn handleKeyEvent(self: *Browser, key: sdl2.Keycode, modifiers: sdl2.KeyModifierSet) !void {
        switch (key) {
            .equals => {
                if (self.activeTab()) |tab| {
                    tab.adjustZoom(0.1);
                    tab.logAccessibilitySettings("zoom in");
                }
                return;
            },
            .minus => {
                if (self.activeTab()) |tab| {
                    tab.adjustZoom(-0.1);
                    tab.logAccessibilitySettings("zoom out");
                }
                return;
            },
            .@"0" => {
                if (self.activeTab()) |tab| {
                    tab.setZoom(1.0);
                    tab.logAccessibilitySettings("zoom reset");
                }
                return;
            },
            .f1 => {
                if (self.activeTab()) |tab| {
                    tab.accessibility.prefers_dark = !tab.accessibility.prefers_dark;
                    self.rebuildTabStyleRules(tab) catch |err| {
                        std.log.warn("Failed to rebuild styles for prefers-color-scheme: {}", .{err});
                    };
                    tab.setNeedsRender();
                    self.active_tab_prefers_dark = tab.accessibility.prefers_dark;
                    tab.logAccessibilitySettings("toggle prefers_dark");
                }
                self.lock.lock();
                self.needs_animation_frame = true;
                self.animation_timer_active = false;
                self.lock.unlock();
                self.scheduleAnimationFrame();
                return;
            },
            .f2 => {
                if (self.activeTab()) |tab| {
                    tab.accessibility.reduce_motion = !tab.accessibility.reduce_motion;
                    tab.setNeedsRender();
                    tab.logAccessibilitySettings("toggle reduce_motion");
                }
                return;
            },
            .f3 => {
                if (self.activeTab()) |tab| {
                    tab.accessibility.screen_reader = !tab.accessibility.screen_reader;
                    tab.setNeedsRender();
                    tab.logAccessibilitySettings("toggle screen_reader");
                    if (tab.accessibility.screen_reader) {
                        tab.dumpAccessibilityTree();
                    }
                }
                return;
            },
            .f4 => {
                if (self.activeTab()) |tab| {
                    tab.readAccessibilityDocument();
                }
                return;
            },
            .f5 => {
                self.handleVoiceCommand();
                return;
            },
            .tab => {
                self.lock.lock();
                const tab = self.activeTab();
                if (tab != null) {
                    self.focus = "content";
                    self.chrome.blur();
                }
                self.lock.unlock();
                if (tab) |active_tab| {
                    const reverse = modifiers.get(.left_shift) or modifiers.get(.right_shift);
                    active_tab.cycleFocus(self, reverse) catch |err| {
                        std.log.warn("Failed to cycle focus: {}", .{err});
                    };
                }
                return;
            },
            .@"return" => {
                const address_bar_focused = self.chrome.isAddressBarFocused();
                const chrome_changed = try self.chrome.enter(self);
                if (chrome_changed) {
                    // Chrome-only update (clear address bar text); avoid recomposite if the display list is unchanged.
                    self.setNeedsRasterDraw();
                    try self.compositeRasterAndDraw();
                    return;
                }

                self.lock.lock();
                const tab = self.activeTab();
                const frame_has_focus = if (tab) |active_tab| blk: {
                    if (active_tab.root_frame) |frame| {
                        break :blk frame.focus != null;
                    }
                    break :blk false;
                } else false;
                const should_activate = shouldRouteContentEditing(
                    address_bar_focused,
                    self.focus,
                    frame_has_focus,
                );
                self.lock.unlock();
                if (should_activate) {
                    if (tab) |active_tab| {
                        _ = active_tab.enter(self) catch |err| {
                            std.log.warn("Failed to handle Enter for focused element: {}", .{err});
                            return;
                        };
                    }
                }
                return;
            },
            .space => {
                const address_bar_focused = self.chrome.isAddressBarFocused();
                self.lock.lock();
                const tab = self.activeTab();
                const frame_has_focus = if (tab) |active_tab| blk: {
                    if (active_tab.root_frame) |frame| {
                        break :blk frame.focus != null;
                    }
                    break :blk false;
                } else false;
                const should_activate = shouldRouteContentEditing(
                    address_bar_focused,
                    self.focus,
                    frame_has_focus,
                );
                self.lock.unlock();
                if (should_activate) {
                    if (tab) |active_tab| {
                        active_tab.activateFocusedElement(self) catch |err| {
                            std.log.warn("Failed to activate focused element: {}", .{err});
                        };
                    }
                }
                return;
            },
            .escape => {
                var should_clear_focus = false;
                var tab_to_clear: ?*Tab = null;
                self.lock.lock();
                if (self.focus) |focus_str| {
                    if (std.mem.eql(u8, focus_str, "content")) {
                        tab_to_clear = self.activeTab();
                        should_clear_focus = true;
                    }
                }
                if (should_clear_focus) {
                    self.focus = null;
                }
                self.lock.unlock();
                if (should_clear_focus) {
                    if (tab_to_clear) |active_tab| {
                        self.scheduleTabBlurTask(active_tab);
                    }
                }
                // Chrome-only update (clear focus UI); avoid recomposite if the display list is unchanged.
                self.setNeedsRasterDraw();
                try self.compositeRasterAndDraw();
                return;
            },
            .backspace => {
                const address_bar_focused = self.chrome.isAddressBarFocused();
                const chrome_changed = self.chrome.backspace();
                self.lock.lock();
                const tab = self.activeTab();
                const frame_has_focus = if (tab) |active_tab| blk: {
                    if (active_tab.root_frame) |frame| {
                        break :blk frame.focus != null;
                    }
                    break :blk false;
                } else false;
                const should_backspace = shouldRouteContentEditing(
                    address_bar_focused,
                    self.focus,
                    frame_has_focus,
                );
                self.lock.unlock();
                if (should_backspace) {
                    if (tab) |active_tab| {
                        self.scheduleTabBackspaceTask(active_tab);
                    }
                }
                if (chrome_changed) {
                    // Chrome-only update (address bar text); avoid recomposite if the display list is unchanged.
                    self.setNeedsRasterDraw();
                    try self.compositeRasterAndDraw();
                }
                return;
            },
            .left => {
                if (self.chrome.moveCursorLeft()) {
                    // Chrome-only update (address cursor); avoid recomposite if the display list is unchanged.
                    self.setNeedsRasterDraw();
                    try self.compositeRasterAndDraw();
                }
                return;
            },
            .right => {
                if (self.chrome.moveCursorRight()) {
                    // Chrome-only update (address cursor); avoid recomposite if the display list is unchanged.
                    self.setNeedsRasterDraw();
                    try self.compositeRasterAndDraw();
                }
                return;
            },
            .down => {
                if (self.activeTab()) |tab| self.scheduleTabScrollTask(tab, scroll_step);
                return;
            },
            .up => {
                if (self.activeTab()) |tab| self.scheduleTabScrollTask(tab, -scroll_step);
                return;
            },
            else => {},
        }
    }

    // Handle mouse clicks to navigate links
    fn handleClick(self: *Browser, screen_x: i32, screen_y: i32) !void {
        self.lock.lock();
        const chrome_bottom = self.chrome.bottom;
        if (screen_y < chrome_bottom) {
            const tab_to_blur = self.activeTab();
            self.lock.unlock();

            // Tab focus is worker-owned. Queue its blur before chrome changes
            // focus so a preceding content click and this chrome click retain
            // their event order on the serialized tab worker.
            if (tab_to_blur) |active_tab| self.scheduleTabBlurTask(active_tab);

            self.lock.lock();
            self.focus = null;
            self.lock.unlock();
            var chrome_changed = try self.chrome.click(self, screen_x, screen_y);
            if (!chrome_changed) {
                // Fallback: focus address bar if click lands in the URL bar region.
                if (screen_y >= self.chrome.urlbar_top and screen_y < self.chrome.urlbar_bottom and
                    screen_x >= self.chrome.address_rect.left and screen_x < self.chrome.address_rect.right)
                {
                    self.chrome.focusAddressBar();
                    chrome_changed = true;
                }
            }
            if (chrome_changed) {
                // Chrome-only update; avoid recomposite if the display list is unchanged.
                self.setNeedsRasterDraw();
                try self.compositeRasterAndDraw();
            }
            return;
        }

        const tab = self.activeTab() orelse {
            self.lock.unlock();
            return;
        };
        const frame = tab.root_frame orelse {
            self.lock.unlock();
            return;
        };
        _ = frame;
        const zoom = self.activeZoom();
        const scroll_device = DisplayItem.scaleLayoutPx(self.active_tab_scroll, zoom);

        self.focus = "content";
        self.chrome.blur();
        self.lock.unlock();

        self.setNeedsCompositeRasterDraw();
        try self.compositeRasterAndDraw();

        const tab_y = screen_y - chrome_bottom;
        const page_y = tab_y +| scroll_device;

        self.scheduleTabClickTask(tab, screen_x, page_y, .primary, zoom);
    }

    // Middle-click only activates links in page content. Chrome and non-link
    // targets are intentionally left unchanged.
    fn handleMiddleClick(self: *Browser, screen_x: i32, screen_y: i32) void {
        self.lock.lock();
        const tab = self.activeTab();
        const chrome_bottom = self.chrome.bottom;
        const zoom = self.activeZoom();
        const frame = if (tab) |active_tab| active_tab.root_frame else null;
        const scroll_device = DisplayItem.scaleLayoutPx(self.active_tab_scroll, zoom);
        self.lock.unlock();

        if (screen_y < chrome_bottom) return;
        const active_tab = tab orelse return;
        _ = frame orelse return;
        const tab_y = screen_y - chrome_bottom;
        const page_y = tab_y +| scroll_device;

        self.scheduleTabClickTask(active_tab, screen_x, page_y, .middle, zoom);
    }

    fn handleHover(self: *Browser, screen_x: i32, screen_y: i32) !void {
        self.lock.lock();
        const tab = self.activeTab();
        const chrome_bottom = self.chrome.bottom;
        const screen_reader_on = if (tab) |active| active.accessibility.screen_reader else false;
        self.lock.unlock();

        if (!screen_reader_on) return;
        const active_tab = tab orelse return;
        const frame = active_tab.root_frame orelse return;
        if (screen_y < chrome_bottom) {
            active_tab.updateAccessibilityHover(null);
            return;
        }

        const tab_y = screen_y - chrome_bottom;
        const zoom = self.activeZoom();
        const page_x = if (zoom == 1.0) screen_x else @as(i32, @intFromFloat(@as(f32, @floatFromInt(screen_x)) / zoom));
        const page_y = (if (zoom == 1.0) tab_y else @as(i32, @intFromFloat(@as(f32, @floatFromInt(tab_y)) / zoom))) + frame.scroll;

        const hit = active_tab.accessibilityHitTest(page_x, page_y);
        active_tab.updateAccessibilityHover(hit);
    }

    fn handleVoiceCommand(self: *Browser) void {
        var buf: [256]u8 = undefined;
        const stdin = std.Io.File.stdin();
        var reader = stdin.reader(self.io, &buf);
        std.log.info("voice command> ", .{});
        const line = reader.interface.takeDelimiter('\n') catch |err| {
            std.log.warn("Failed to read command: {}", .{err});
            return;
        };
        const raw = line orelse return;
        const command = std.mem.trim(u8, raw, " \t\r\n");
        if (command.len == 0) return;

        if (self.activeTab()) |tab| {
            tab.handleVoiceCommand(self, command);
        }
    }

    fn scheduleTabClickTask(self: *Browser, tab: *Tab, x: i32, y: i32, button: ClickButton, zoom: f32) void {
        const ctx = TabClickTaskContext.create(self.allocator, self, tab, x, y, button, zoom) catch |err| {
            std.log.err("Failed to allocate tab click task: {}", .{err});
            return;
        };
        const task_instance = Task.init(
            ctx.toOpaque(),
            TabClickTaskContext.runOpaque,
            TabClickTaskContext.cleanupOpaque,
        );
        tab.task_runner.schedule(task_instance) catch |err| {
            std.log.err("Failed to schedule tab click: {}", .{err});
            ctx.destroy();
            return;
        };
    }

    fn scheduleTabKeypressTask(self: *Browser, tab: *Tab, char: u8) void {
        const ctx = TabKeypressTaskContext.create(self.allocator, self, tab, char) catch |err| {
            std.log.err("Failed to allocate keypress task: {}", .{err});
            return;
        };
        const task_instance = Task.init(
            ctx.toOpaque(),
            TabKeypressTaskContext.runOpaque,
            TabKeypressTaskContext.cleanupOpaque,
        );
        tab.task_runner.schedule(task_instance) catch |err| {
            std.log.err("Failed to schedule keypress: {}", .{err});
            ctx.destroy();
            return;
        };
    }

    fn scheduleTabBackspaceTask(self: *Browser, tab: *Tab) void {
        const ctx = TabBackspaceTaskContext.create(self.allocator, self, tab) catch |err| {
            std.log.err("Failed to allocate backspace task: {}", .{err});
            return;
        };
        const task_instance = Task.init(
            ctx.toOpaque(),
            TabBackspaceTaskContext.runOpaque,
            TabBackspaceTaskContext.cleanupOpaque,
        );
        tab.task_runner.schedule(task_instance) catch |err| {
            std.log.err("Failed to schedule backspace: {}", .{err});
            ctx.destroy();
            return;
        };
    }

    fn scheduleTabScrollTask(self: *Browser, tab: *Tab, delta: i32) void {
        const ctx = TabScrollTaskContext.create(self.allocator, self, tab, delta) catch |err| {
            std.log.err("Failed to allocate tab scroll task: {}", .{err});
            return;
        };
        const task_instance = Task.init(
            ctx.toOpaque(),
            TabScrollTaskContext.runOpaque,
            TabScrollTaskContext.cleanupOpaque,
        );
        tab.task_runner.schedule(task_instance) catch |err| {
            std.log.err("Failed to schedule tab scroll: {}", .{err});
            ctx.destroy();
            return;
        };
    }

    pub fn scheduleTabHistoryTraversal(
        self: *Browser,
        tab: *Tab,
        direction: HistoryDirection,
    ) void {
        const ctx = TabHistoryTaskContext.create(
            self.allocator,
            self,
            tab,
            .{ .direction = direction },
        ) catch |err| {
            std.log.err("Failed to allocate history traversal task: {}", .{err});
            return;
        };
        const task_instance = Task.init(
            ctx.toOpaque(),
            TabHistoryTaskContext.runOpaque,
            TabHistoryTaskContext.cleanupOpaque,
        );
        tab.task_runner.schedule(task_instance) catch |err| {
            std.log.err("Failed to schedule history traversal: {}", .{err});
            ctx.destroy();
            return;
        };
    }

    fn scheduleConfirmedPostResubmission(
        self: *Browser,
        request: PendingPostResubmission,
    ) void {
        const ctx = TabHistoryTaskContext.create(
            self.allocator,
            self,
            request.tab,
            .{ .resubmit = .{
                .target = request.target,
                .history_generation = request.history_generation,
            } },
        ) catch |err| {
            std.log.err("Failed to allocate POST resubmission task: {}", .{err});
            return;
        };
        const task_instance = Task.init(
            ctx.toOpaque(),
            TabHistoryTaskContext.runOpaque,
            TabHistoryTaskContext.cleanupOpaque,
        );
        request.tab.task_runner.schedule(task_instance) catch |err| {
            std.log.err("Failed to schedule POST resubmission: {}", .{err});
            ctx.destroy();
        };
    }

    /// Called only by the serialized tab worker. The UI thread validates that
    /// the originating tab is still active before displaying the modal prompt.
    pub fn requestPostResubmission(
        self: *Browser,
        tab: *Tab,
        target: usize,
        history_generation: u64,
    ) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.shutting_down or self.activeTab() != tab) return;
        if (self.pending_post_resubmission != null or self.post_resubmission_dialog_active) return;
        self.pending_post_resubmission = .{
            .tab = tab,
            .target = target,
            .history_generation = history_generation,
        };
    }

    fn scheduleTabBlurTask(self: *Browser, tab: *Tab) void {
        const ctx = TabBlurTaskContext.create(self.allocator, self, tab) catch |err| {
            std.log.err("Failed to allocate tab blur task: {}", .{err});
            return;
        };
        const task_instance = Task.init(
            ctx.toOpaque(),
            TabBlurTaskContext.runOpaque,
            TabBlurTaskContext.cleanupOpaque,
        );
        tab.task_runner.schedule(task_instance) catch |err| {
            std.log.err("Failed to schedule tab blur: {}", .{err});
            ctx.destroy();
            return;
        };
    }

    fn scheduleTabResizeTask(
        self: *Browser,
        tab: *Tab,
        width: i32,
        height: i32,
        generation: u64,
    ) void {
        const ctx = TabResizeTaskContext.create(
            self.allocator,
            self,
            tab,
            width,
            height,
            generation,
        ) catch |err| {
            std.log.err("Failed to allocate tab resize task: {}", .{err});
            return;
        };
        const task_instance = Task.init(
            ctx.toOpaque(),
            TabResizeTaskContext.runOpaque,
            TabResizeTaskContext.cleanupOpaque,
        );
        tab.task_runner.schedule(task_instance) catch |err| {
            std.log.err("Failed to schedule tab resize: {}", .{err});
            ctx.destroy();
            return;
        };
    }

    // Update the scroll offset
    pub fn fetchBody(self: *Browser, url: Url, referrer: ?Url, payload: ?[]const u8) !url_module.HttpResponse {
        return self.fetchBodyWithReferrerPolicy(url, referrer, payload, .default);
    }

    fn fetchBodyWithReferrerPolicy(
        self: *Browser,
        url: Url,
        referrer: ?Url,
        payload: ?[]const u8,
        referrer_policy: url_module.ReferrerPolicy,
    ) !url_module.HttpResponse {
        self.session_state.network_lock.lock();
        defer self.session_state.network_lock.unlock();

        return url_module.Url.fetchBodyWithReferrerPolicy(
            self.allocator,
            self.io,
            &self.session_state.http_client,
            &self.session_state.cookie_jar,
            &self.session_state.http_cache,
            url,
            referrer,
            payload,
            referrer_policy,
        );
    }

    fn fetchBodyWithOrigin(
        self: *Browser,
        url: Url,
        referrer: ?Url,
        payload: ?[]const u8,
        request_origin: []const u8,
        referrer_policy: url_module.ReferrerPolicy,
    ) !url_module.HttpResponse {
        self.session_state.network_lock.lock();
        defer self.session_state.network_lock.unlock();

        return url_module.Url.fetchBodyWithOriginAndReferrerPolicy(
            self.allocator,
            self.io,
            &self.session_state.http_client,
            &self.session_state.cookie_jar,
            &self.session_state.http_cache,
            url,
            referrer,
            payload,
            request_origin,
            referrer_policy,
        );
    }

    fn fetchBodyForNavigation(
        self: *Browser,
        url: Url,
        referrer: ?Url,
        payload: ?[]const u8,
        final_url: *?Url,
        referrer_policy: url_module.ReferrerPolicy,
    ) !url_module.HttpResponse {
        self.session_state.network_lock.lock();
        defer self.session_state.network_lock.unlock();

        return url_module.Url.fetchBodyWithFinalUrlAndReferrerPolicy(
            self.allocator,
            self.io,
            &self.session_state.http_client,
            &self.session_state.cookie_jar,
            &self.session_state.http_cache,
            url,
            referrer,
            payload,
            final_url,
            referrer_policy,
        );
    }

    /// Fetch or generate a navigated document with explicit response-body
    /// ownership. Passing final_url enables HTTP redirect destination output.
    pub fn fetchNavigationDocument(
        self: *Browser,
        url: Url,
        referrer: ?Url,
        payload: ?[]const u8,
        final_url: ?*?Url,
    ) !NavigationDocument {
        return self.fetchNavigationDocumentWithReferrerPolicy(
            url,
            referrer,
            payload,
            final_url,
            .default,
        );
    }

    fn fetchNavigationDocumentWithReferrerPolicy(
        self: *Browser,
        url: Url,
        referrer: ?Url,
        payload: ?[]const u8,
        final_url: ?*?Url,
        referrer_policy: url_module.ReferrerPolicy,
    ) !NavigationDocument {
        if (final_url) |output| output.* = null;

        if (url.isAboutBookmarks()) {
            const body = try self.session_state.bookmarksPageHtml(self.allocator);
            return .{
                .response = .{ .body = body },
                .owned_body = body,
            };
        }

        const response = if (final_url) |output|
            self.fetchBodyForNavigation(url, referrer, payload, output, referrer_policy) catch |err| {
                if (!url_module.Url.isCertificateError(err)) return err;
                const body = try certificateWarningHtml(self.allocator, &url, err);
                return .{
                    .response = .{ .body = body },
                    .owned_body = body,
                    .certificate_error = true,
                };
            }
        else
            self.fetchBodyWithReferrerPolicy(url, referrer, payload, referrer_policy) catch |err| {
                if (!url_module.Url.isCertificateError(err)) return err;
                const body = try certificateWarningHtml(self.allocator, &url, err);
                return .{
                    .response = .{ .body = body },
                    .owned_body = body,
                    .certificate_error = true,
                };
            };
        const body_is_owned = !std.mem.eql(u8, url.scheme, "about") and
            !std.mem.eql(u8, url.scheme, "data");
        return .{
            .response = response,
            .owned_body = if (body_is_owned) response.body else null,
        };
    }

    fn attachJsCallbacks(
        self: *Browser,
        tab: *Tab,
        frame: *Frame,
        js_context: *js_module,
    ) void {
        _ = tab.activateDocumentGeneration(frame);
        const render_context = &frame.js_render_context;
        render_context.setPointers(
            @as(?*anyopaque, @ptrCast(self)),
            @as(?*anyopaque, @ptrCast(tab)),
            js_context,
            frame.window_id,
        );

        frame.js_render_context_initialized = true;
        js_context.setNodes(frame.window_id, &frame.current_node.?);
        js_context.setRenderCallback(frame.window_id, jsRenderCallback, @ptrCast(render_context));
        js_context.setDomMutationCallback(
            frame.window_id,
            jsDomMutationCallback,
            @ptrCast(render_context),
        );
        js_context.setXhrCallback(frame.window_id, jsXhrCallback, @ptrCast(render_context));
        js_context.setCookieCallbacks(
            frame.window_id,
            jsCookieGetCallback,
            jsCookieSetCallback,
            @ptrCast(render_context),
        );
        js_context.setAnimationFrameCallback(
            frame.window_id,
            jsRequestAnimationFrameCallback,
            @ptrCast(render_context),
        );
        js_context.setSetTimeoutCallback(
            frame.window_id,
            jsSetTimeoutCallback,
            @ptrCast(render_context),
        );
        js_context.setPostMessageCallback(
            frame.window_id,
            jsPostMessageCallback,
            @ptrCast(render_context),
        );
    }

    // Send request to a URL, load response into a tab
    pub fn loadInTab(
        self: *Browser,
        tab: *Tab,
        url: *Url,
        payload: ?[]const u8,
        history_navigation: HistoryNavigation,
    ) !void {
        std.log.info("Loading: {s}", .{url.*.path});

        var referrer_value: ?Url = null;
        var referrer_policy: url_module.ReferrerPolicy = .default;
        if (tab.root_frame) |old_frame| {
            referrer_policy = old_frame.referrer_policy;
            if (old_frame.current_url) |ref_ptr| {
                referrer_value = ref_ptr.*;
            }
        }

        // Fetch and decode while the old document still owns the referrer and
        // remains usable if navigation fails before commit.
        var final_url: ?Url = null;
        errdefer if (final_url) |resolved| resolved.free(self.allocator);
        var document = try self.fetchNavigationDocumentWithReferrerPolicy(
            url.*,
            referrer_value,
            payload,
            &final_url,
            referrer_policy,
        );
        defer document.deinit(self.allocator);
        const response = document.response;

        // The requested link and its final redirect destination are distinct
        // visits. A certificate warning is browser UI, not a successful visit
        // to the untrusted destination.
        if (!document.certificate_error) {
            try self.recordSuccessfulNavigation(url, &final_url);
        }
        const raw_body = response.body;
        const body_text = try decodeUtf8Replace(self.allocator, raw_body);
        var body_text_owned = true;
        defer if (body_text_owned) self.allocator.free(body_text);
        var document_title: ?[:0]u8 = null;
        defer if (document_title) |title| self.allocator.free(title);

        // History owns an independent replay copy of a POST body. Complete
        // those allocations before retiring the old document so an OOM leaves
        // both the current page and history untouched.
        var prepared_history = try tab.prepareHistoryNavigation(
            url,
            payload,
            history_navigation,
        );
        defer prepared_history.deinit(tab.allocator);

        tab.task_runner.clear();
        tab.invalidateJsContext();
        self.retireRenderStateForTab(tab);
        if (tab.root_frame) |old_frame| {
            old_frame.deinit();
            tab.allocator.destroy(old_frame);
            tab.root_frame = null;
        }

        const frame = try tab.allocator.create(Frame);
        frame.* = Frame.init(tab.allocator, tab, null, null);
        tab.root_frame = frame;
        tab.registerFrame(frame);
        frame.viewport_width = tab.tab_width;
        frame.viewport_height = tab.tab_height;
        frame.certificate_error = document.certificate_error;
        frame.referrer_policy = response.referrer_policy;
        tab.focused_frame = frame;

        frame.scroll = 0;
        tab.scroll_changed_in_tab = true;

        frame.clearAllowedOrigins();
        if (response.csp_header) |hdr| {
            frame.applyContentSecurityPolicy(hdr, url.*) catch |err| {
                std.log.warn("Failed to apply Content-Security-Policy: {}", .{err});
            };
        }

        // Free previous HTML source if it exists
        if (frame.current_node) |node| {
            var n = node;
            n.deinit(self.allocator);
            frame.current_node = null;
        }

        if (frame.current_html_source) |old_source| {
            self.allocator.free(old_source);
            frame.current_html_source = null;
        }

        if (url.*.view_source and !document.certificate_error) {
            // Use the new layoutSourceCode function for view-source mode
            self.layout_engine.accessibility = tab.accessibility;

            if (frame.display_list) |items| {
                DisplayItem.freeList(self.allocator, items);
            }

            if (frame.document_layout) |doc| {
                doc.deinit();
                self.allocator.destroy(doc);
                frame.document_layout = null;
            }

            if (frame.current_node) |node| {
                var n = node;
                n.deinit(self.allocator);
                frame.current_node = null;
            }

            frame.display_list = try self.layout_engine.layoutSourceCode(body_text);
            frame.content_height = self.layout_engine.content_height;
        } else {
            // Parse HTML into a node tree
            var html_parser = try HTMLParser.init(self.allocator, body_text);
            defer html_parser.deinit(self.allocator);

            // Clear any previous node tree
            if (frame.current_node) |node| {
                var n = node;
                n.deinit(self.allocator);
                frame.current_node = null;
            }

            // Parse the HTML and store the root node
            frame.current_node = try html_parser.parse();
            document_title = try parser.collectDocumentTitle(
                self.allocator,
                &frame.current_node.?,
            );

            // IMPORTANT: Fix parent pointers after copying the tree
            // The parse() method returns the tree by value, which copies it,
            // but the parent pointers still point to the old locations
            parser.fixParentPointers(&frame.current_node.?, null);
            try self.annotateVisitedLinks(&frame.current_node.?, url);

            // Store the HTML source (it contains slices used by the tree)
            // Only store if it's not an about: URL (those return static strings)
            frame.current_html_source = body_text;
            body_text_owned = false;

            // Update the JS engine with the current nodes for DOM API
            frame.js_context = try tab.getJs(url);
            if (frame.js_context) |ctx| {
                self.attachJsCallbacks(tab, frame, ctx);
            }
            tab.setParentWindow(frame.window_id, null);
            if (frame.js_context) |ctx| {
                ctx.setParentWindow(frame.window_id, null);
            }

            // Find all scripts and stylesheets
            var node_list = std.ArrayList(*parser.Node).empty;
            defer node_list.deinit(self.allocator);
            try parser.treeToList(self.allocator, &frame.current_node.?, &node_list);

            // Download and decode <img> elements before layout/paint.
            self.loadImages(frame, url, node_list.items) catch |err| {
                std.log.warn("Failed to load images: {}", .{err});
            };

            // Queue scripts in document order and mark their element identity
            // so later resource rescans do not evaluate them again.
            _ = self.scheduleDocumentScripts(tab, frame, url, node_list.items);

            // Create and load iframe subdocuments after scheduling parent scripts.
            self.loadIframes(frame, url, node_list.items) catch |err| {
                std.log.warn("Failed to load iframes: {}", .{err});
            };

            // Note: We use self.allocator directly for CSS parsing instead of an arena
            // because the CSS rules need to live as long as the Tab (for re-rendering)

            // Load and parse author stylesheets. Rules borrow their property
            // strings from these buffers, so stage both collections and commit
            // them to the frame together.
            var new_css_texts = std.ArrayList([]const u8).empty;
            defer {
                for (new_css_texts.items) |css_text| {
                    self.allocator.free(css_text);
                }
                new_css_texts.deinit(self.allocator);
            }

            var all_rules = std.ArrayList(CSSParser.CSSRule).empty;

            // Track how many default rules we have so we don't double-free them
            const default_rules_count = self.default_style_sheet_rules.len;

            defer {
                for (all_rules.items) |*rule| {
                    if (rule.owned) {
                        rule.deinit(self.allocator);
                    }
                }
                all_rules.deinit(self.allocator);
            }

            // Start with default browser stylesheet rules (shallow copy, browser still owns them)
            for (self.default_style_sheet_rules) |rule| {
                try all_rules.append(self.allocator, rule);
            }

            try self.appendDocumentStylesheets(
                frame,
                url,
                node_list.items,
                &new_css_texts,
                &all_rules,
            );

            // Sort rules by cascade priority (more specific selectors override less specific)
            // Stable sort preserves file order for rules with equal priority
            std.mem.sort(CSSParser.CSSRule, all_rules.items, {}, struct {
                fn lessThan(_: void, a: CSSParser.CSSRule, b: CSSParser.CSSRule) bool {
                    return a.cascadePriority() < b.cascadePriority();
                }
            }.lessThan);

            // Clean up the old generation before transferring the staged one.
            for (frame.rules.items) |*rule| {
                if (rule.owned) {
                    rule.deinit(self.allocator);
                }
            }
            frame.rules.deinit(self.allocator);

            for (frame.css_texts.items) |old_css_text| {
                self.allocator.free(old_css_text);
            }
            frame.css_texts.deinit(self.allocator);

            frame.default_rules_count = default_rules_count;
            frame.rules = all_rules;
            all_rules = .empty;
            frame.css_texts = new_css_texts;
            new_css_texts = .empty;

            // Apply all stylesheet rules and inline styles (sorted by cascade order)
            try parser.style(self.allocator, &frame.current_node.?, frame.rules.items);

            // Layout using the HTML node tree
            try self.layoutTabNodes(frame, true);
        }

        if (url.*.fragment()) |fragment| {
            _ = frame.scrollToFragment(fragment);
        }

        // Commit history only after the new document is ready. Ordinary
        // navigation truncates a forward branch; traversal replaces the
        // canonical target with the final URL after redirects.
        tab.commitPreparedHistoryNavigation(&prepared_history);
        frame.current_url = url;
        frame.current_url_owned = false;
        self.updateTabTitle(tab, document_title);
        document_title = null;
        tab.setNeedsRender();
        // Render and commit immediately to ensure first paint even if animation scheduling stalls.
        tab.runAnimationFrame(frame.scroll);
    }

    pub fn scheduleLoad(
        self: *Browser,
        tab: *Tab,
        url: *Url,
        payload: ?[]const u8,
    ) !void {
        const ctx = try LoadTaskContext.create(
            self.allocator,
            self,
            tab,
            url,
            payload,
        );
        tab.task_runner.clear();
        const task_instance = Task.init(
            ctx.toOpaque(),
            LoadTaskContext.runOpaque,
            LoadTaskContext.cleanupOpaque,
        );
        tab.task_runner.schedule(task_instance) catch |err| {
            ctx.destroy();
            return err;
        };
    }

    pub fn scheduleFrameLoad(
        self: *Browser,
        frame: *Frame,
        url: *Url,
        payload: ?[]const u8,
    ) !void {
        std.log.info("Scheduling iframe load for window_id={d}: {s}", .{ frame.window_id, url.*.path });
        const ctx = try FrameLoadTaskContext.create(
            self.allocator,
            self,
            frame,
            url,
            payload,
        );
        const task_instance = Task.init(
            ctx.toOpaque(),
            FrameLoadTaskContext.runOpaque,
            FrameLoadTaskContext.cleanupOpaque,
        );
        frame.tab.task_runner.schedule(task_instance) catch |err| {
            ctx.destroy();
            return err;
        };
    }

    fn resetFrameForNavigation(self: *Browser, frame: *Frame) void {
        if (frame.js_context) |ctx| {
            ctx.setNodes(frame.window_id, null);
        }
        frame.document_generation = 0;
        frame.js_render_context.setGeneration(0);
        frame.js_render_context.setPointers(null, null, null, 0);
        frame.js_context = null;
        frame.js_render_context_initialized = false;

        // Source metadata in the retained list borrows this layout/DOM
        // generation, so it must be gone before either tree is rebuilt.
        frame.retireDisplayList();

        frame.input_bounds.clearRetainingCapacity();
        frame.link_bounds.clearRetainingCapacity();
        frame.iframe_bounds.clearRetainingCapacity();
        frame.focus_bounds.clearRetainingCapacity();
        frame.accessibility_bounds.clearRetainingCapacity();
        frame.fragment_targets.clearRetainingCapacity();

        for (frame.children.items) |child| {
            child.deinit();
            frame.allocator.destroy(child);
        }
        frame.children.clearRetainingCapacity();

        if (frame.document_layout) |doc| {
            doc.deinit();
            self.allocator.destroy(doc);
            frame.document_layout = null;
        }

        if (frame.current_node) |*node| {
            node.deinit(self.allocator);
            frame.current_node = null;
        }

        for (frame.rules.items) |*rule| {
            if (rule.owned) {
                rule.deinit(self.allocator);
            }
        }
        frame.rules.clearRetainingCapacity();
        frame.default_rules_count = 0;

        for (frame.css_texts.items) |css_text| {
            self.allocator.free(css_text);
        }
        frame.css_texts.clearRetainingCapacity();

        if (frame.current_html_source) |old_source| {
            self.allocator.free(old_source);
            frame.current_html_source = null;
        }

        if (frame.current_url_owned) {
            if (frame.current_url) |url_ptr| {
                url_ptr.*.free(self.allocator);
                self.allocator.destroy(url_ptr);
            }
        }
        frame.current_url = null;
        frame.current_url_owned = false;
        frame.certificate_error = false;
        frame.referrer_policy = .default;
        frame.resources_dirty = false;
        frame.content_height = 0;
        frame.scroll = 0;
        frame.focus = null;
        frame.scroll_focus = null;

        frame.clearAllowedOrigins();
    }

    pub fn loadInFrame(
        self: *Browser,
        frame: *Frame,
        url: *Url,
        payload: ?[]const u8,
    ) !void {
        std.log.info("Loading iframe: {s}", .{url.*.path});

        if (frame.parent) |parent| {
            if (parent.current_url) |page_url| {
                if (!iframeNavigationAllowed(parent, page_url, url, null)) {
                    std.log.warn("Blocked iframe navigation to {s} due to CSP", .{url.*.path});
                    return error.IframeNavigationBlockedByCsp;
                }
            }
        }

        var referrer_value: ?Url = null;
        const referrer_policy = frame.referrer_policy;
        if (frame.current_url) |ref_ptr| {
            referrer_value = ref_ptr.*;
        }

        var final_url: ?Url = null;
        errdefer if (final_url) |resolved| resolved.free(self.allocator);
        var document = try self.fetchNavigationDocumentWithReferrerPolicy(
            url.*,
            referrer_value,
            payload,
            &final_url,
            referrer_policy,
        );
        defer document.deinit(self.allocator);
        const response = document.response;

        const final_destination: ?*const Url = if (final_url) |*resolved| resolved else null;
        if (frame.parent) |parent| {
            if (parent.current_url) |page_url| {
                if (!iframeNavigationAllowed(parent, page_url, url, final_destination)) {
                    std.log.warn("Blocked redirected iframe navigation to {s} due to CSP", .{url.*.path});
                    return error.IframeRedirectBlockedByCsp;
                }
            }
        }

        if (!document.certificate_error) {
            try self.recordSuccessfulNavigation(url, &final_url);
        }

        const raw_body = response.body;
        const body_text = try decodeUtf8Replace(self.allocator, raw_body);
        var body_text_owned = true;
        errdefer if (body_text_owned) self.allocator.free(body_text);

        const frame_url = try self.allocator.create(Url);
        var frame_url_owned = true;
        defer if (frame_url_owned) self.allocator.destroy(frame_url);
        frame_url.* = url.*.clone(self.allocator) catch |err| {
            self.allocator.destroy(frame_url);
            frame_url_owned = false;
            return err;
        };
        defer if (frame_url_owned) frame_url.*.free(self.allocator);

        // The old child-frame URL owns the storage borrowed by referrer_value.
        // Keep the old document generation alive through fetch/decode, then
        // retire it before installing the response as the new generation.
        self.retireRenderStateForTab(frame.tab);
        self.resetFrameForNavigation(frame);
        frame.certificate_error = document.certificate_error;
        frame.referrer_policy = response.referrer_policy;

        frame.clearAllowedOrigins();
        if (response.csp_header) |hdr| {
            frame.applyContentSecurityPolicy(hdr, url.*) catch |err| {
                std.log.warn("Failed to apply Content-Security-Policy: {}", .{err});
            };
        }

        var html_parser = try HTMLParser.init(self.allocator, body_text);
        defer html_parser.deinit(self.allocator);

        frame.current_node = try html_parser.parse();
        parser.fixParentPointers(&frame.current_node.?, null);
        try self.annotateVisitedLinks(&frame.current_node.?, url);
        frame.current_html_source = body_text;
        body_text_owned = false;

        frame.current_url = frame_url;
        frame.current_url_owned = true;
        frame_url_owned = false;

        frame.js_context = try frame.tab.getJs(url);
        if (frame.js_context) |ctx| {
            self.attachJsCallbacks(frame.tab, frame, ctx);
        }

        var parent_window_id: ?u32 = null;
        if (frame.parent) |parent| {
            if (parent.current_url != null and frame.current_url != null) {
                if (parent.current_url.?.*.sameOrigin(frame.current_url.?.*) or
                    (std.mem.eql(u8, parent.current_url.?.*.scheme, "file") and std.mem.eql(u8, frame.current_url.?.*.scheme, "file")))
                {
                    parent_window_id = parent.window_id;
                }
            }
        }
        frame.tab.setParentWindow(frame.window_id, parent_window_id);
        if (frame.js_context) |ctx| {
            if (parent_window_id != null and frame.parent != null and frame.parent.?.js_context != null and frame.parent.?.js_context == ctx) {
                ctx.setParentWindow(frame.window_id, parent_window_id);
            } else {
                ctx.setParentWindow(frame.window_id, null);
            }
        }

        var node_list = std.ArrayList(*parser.Node).empty;
        defer node_list.deinit(self.allocator);
        try parser.treeToList(self.allocator, &frame.current_node.?, &node_list);

        self.loadImages(frame, url, node_list.items) catch |err| {
            std.log.warn("Failed to load iframe images: {}", .{err});
        };

        _ = self.scheduleDocumentScripts(frame.tab, frame, url, node_list.items);

        // Load nested iframes in this frame.
        self.loadIframes(frame, url, node_list.items) catch |err| {
            std.log.warn("Failed to load iframe subdocuments: {}", .{err});
        };

        var new_css_texts = std.ArrayList([]const u8).empty;
        defer {
            for (new_css_texts.items) |css_text| self.allocator.free(css_text);
            new_css_texts.deinit(self.allocator);
        }

        var all_rules = std.ArrayList(CSSParser.CSSRule).empty;
        const default_rules_count = self.default_style_sheet_rules.len;
        defer {
            for (all_rules.items) |*rule| {
                if (rule.owned) {
                    rule.deinit(self.allocator);
                }
            }
            all_rules.deinit(self.allocator);
        }

        for (self.default_style_sheet_rules) |rule| {
            try all_rules.append(self.allocator, rule);
        }

        try self.appendDocumentStylesheets(
            frame,
            url,
            node_list.items,
            &new_css_texts,
            &all_rules,
        );

        std.mem.sort(CSSParser.CSSRule, all_rules.items, {}, struct {
            fn lessThan(_: void, a: CSSParser.CSSRule, b: CSSParser.CSSRule) bool {
                return a.cascadePriority() < b.cascadePriority();
            }
        }.lessThan);

        // resetFrameForNavigation left these lists empty but retained their
        // buffers. Replace both generations together so rules never outlive
        // the stylesheet text they borrow.
        frame.rules.deinit(self.allocator);
        frame.css_texts.deinit(self.allocator);
        frame.default_rules_count = default_rules_count;
        frame.rules = all_rules;
        all_rules = .empty;
        frame.css_texts = new_css_texts;
        new_css_texts = .empty;

        try parser.style(self.allocator, &frame.current_node.?, frame.rules.items);
        try self.layoutTabNodes(frame, true);
        if (url.*.fragment()) |fragment| {
            _ = frame.scrollToFragment(fragment);
        }

        frame.tab.setNeedsRender();
        frame.tab.runAnimationFrame(frame.scroll);
    }

    fn loadImages(self: *Browser, frame: *Frame, page_url: *Url, nodes: []*Node) !void {
        const ImageCacheEntry = struct {
            width: usize,
            height: usize,
            pixels: []const u8,
        };

        var image_cache = std.StringHashMap(ImageCacheEntry).init(self.allocator);
        defer {
            var it = image_cache.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.pixels);
            }
            image_cache.deinit();
        }

        for (nodes) |node| {
            switch (node.*) {
                .element => |*element| {
                    if (!std.mem.eql(u8, element.tag, "img")) continue;
                    const attrs = element.attributes orelse continue;
                    const src = attrs.get("src") orelse continue;
                    if (src.len == 0) continue;

                    var image_url = page_url.*.resolve(self.allocator, src) catch |err| {
                        std.log.warn("Failed to resolve image URL {s}: {}", .{ src, err });
                        if (element.image_data) |*existing| {
                            existing.deinit(self.allocator);
                        }
                        const broken = try createBrokenImage(self.allocator);
                        element.image_data = ImageData{
                            .encoded_bytes = null,
                            .image = broken,
                        };
                        continue;
                    };
                    defer image_url.free(self.allocator);

                    if (!frame.allowedRequest(image_url, page_url)) {
                        std.log.warn("Blocked image {s} due to CSP", .{src});
                        continue;
                    }

                    const cache_key = try self.allocator.dupe(u8, image_url.path);
                    if (image_cache.get(cache_key)) |entry| {
                        self.allocator.free(cache_key);
                        const pixels_copy = try self.allocator.dupe(u8, entry.pixels);
                        const image = try zigimg.Image.fromRawPixelsOwned(entry.width, entry.height, pixels_copy, .rgba32);
                        if (element.image_data) |*existing| {
                            existing.deinit(self.allocator);
                        }
                        element.image_data = ImageData{
                            .encoded_bytes = null,
                            .image = image,
                        };
                        continue;
                    }

                    const image_response = self.fetchBodyWithReferrerPolicy(
                        image_url,
                        page_url.*,
                        null,
                        frame.referrer_policy,
                    ) catch |err| {
                        std.log.warn("Failed to load image {s}: {}", .{ src, err });
                        self.allocator.free(cache_key);
                        if (element.image_data) |*existing| {
                            existing.deinit(self.allocator);
                        }
                        const broken = try createBrokenImage(self.allocator);
                        element.image_data = ImageData{
                            .encoded_bytes = null,
                            .image = broken,
                        };
                        continue;
                    };
                    defer if (image_response.csp_header) |hdr| self.allocator.free(hdr);

                    var encoded_bytes = image_response.body;
                    if (std.mem.eql(u8, image_url.scheme, "data") or std.mem.eql(u8, image_url.scheme, "about")) {
                        const copy = try self.allocator.alloc(u8, encoded_bytes.len);
                        @memcpy(copy, encoded_bytes);
                        encoded_bytes = copy;
                    }

                    var image = zigimg.Image.fromMemory(self.allocator, encoded_bytes) catch |err| {
                        std.log.warn("Failed to decode image {s}: {}", .{ src, err });
                        self.allocator.free(encoded_bytes);
                        self.allocator.free(cache_key);
                        if (element.image_data) |*existing| {
                            existing.deinit(self.allocator);
                        }
                        const broken = try createBrokenImage(self.allocator);
                        element.image_data = ImageData{
                            .encoded_bytes = null,
                            .image = broken,
                        };
                        continue;
                    };

                    image.convert(self.allocator, .rgba32) catch |err| {
                        std.log.warn("Failed to convert image {s} to RGBA: {}", .{ src, err });
                        image.deinit(self.allocator);
                        self.allocator.free(encoded_bytes);
                        self.allocator.free(cache_key);
                        if (element.image_data) |*existing| {
                            existing.deinit(self.allocator);
                        }
                        const broken = try createBrokenImage(self.allocator);
                        element.image_data = ImageData{
                            .encoded_bytes = null,
                            .image = broken,
                        };
                        continue;
                    };

                    const cached_pixels = try self.allocator.dupe(u8, image.rawBytes());
                    try image_cache.put(cache_key, .{
                        .width = image.width,
                        .height = image.height,
                        .pixels = cached_pixels,
                    });

                    if (element.image_data) |*existing| {
                        existing.deinit(self.allocator);
                    }
                    element.image_data = ImageData{
                        .encoded_bytes = encoded_bytes,
                        .image = image,
                    };
                },
                .text => {},
            }
        }
    }

    fn loadIframes(self: *Browser, parent: *Frame, page_url: *Url, nodes: []*Node) !void {
        for (nodes) |node| {
            switch (node.*) {
                .element => |*element| {
                    if (!std.mem.eql(u8, element.tag, "iframe")) continue;
                    const attrs = element.attributes orelse continue;
                    const src = attrs.get("src") orelse continue;
                    if (src.len == 0) continue;
                    self.loadIframe(parent, node, page_url, src) catch |err| {
                        std.log.warn("Failed to load iframe {s}: {}", .{ src, err });
                    };
                },
                .text => {},
            }
        }
    }

    fn parseLengthAttribute(value: []const u8) ?i32 {
        if (value.len == 0) return null;
        if (std.mem.endsWith(u8, value, "px")) {
            const num_str = value[0 .. value.len - 2];
            return std.fmt.parseInt(i32, num_str, 10) catch null;
        }
        return std.fmt.parseInt(i32, value, 10) catch null;
    }

    fn iframeViewportFromNode(node: *Node) ?struct { width: i32, height: i32 } {
        const element = switch (node.*) {
            .element => |e| e,
            else => return null,
        };
        if (!std.mem.eql(u8, element.tag, "iframe")) return null;

        var width: i32 = 300;
        var height: i32 = 150;

        if (element.attributes) |attrs| {
            if (attrs.get("width")) |width_str| {
                if (parseLengthAttribute(width_str)) |parsed_width| {
                    width = parsed_width;
                }
            }
            if (attrs.get("height")) |height_str| {
                if (parseLengthAttribute(height_str)) |parsed_height| {
                    height = parsed_height;
                }
            }
        }

        if (width <= 0 or height <= 0) return null;
        return .{ .width = width, .height = height };
    }

    /// A parent document's CSP applies to the response's final destination,
    /// not only the URL named by the iframe element. The optional URL is a
    /// synchronous borrow owned by the navigation fetch result.
    pub fn iframeRedirectAllowed(
        parent: *Frame,
        page_url: *const Url,
        final_destination: ?*const Url,
    ) bool {
        const destination = final_destination orelse return true;
        return parent.allowedRequest(destination.*, page_url);
    }

    /// Check both the authored target and any final redirect before an iframe
    /// document is recorded or installed. This is shared by initial iframe
    /// creation and later navigation within an existing child frame.
    pub fn iframeNavigationAllowed(
        parent: *Frame,
        page_url: *const Url,
        requested_destination: *const Url,
        final_destination: ?*const Url,
    ) bool {
        return parent.allowedRequest(requested_destination.*, page_url) and
            iframeRedirectAllowed(parent, page_url, final_destination);
    }

    fn loadIframe(self: *Browser, parent: *Frame, iframe_node: *Node, page_url: *Url, src: []const u8) !void {
        var iframe_url = try page_url.*.resolveForNavigation(self.allocator, src);
        var url_owned = true;
        defer if (url_owned) iframe_url.free(self.allocator);

        if (!iframeNavigationAllowed(parent, page_url, &iframe_url, null)) {
            std.log.warn("Blocked iframe {s} due to CSP", .{src});
            return;
        }

        var final_url: ?Url = null;
        errdefer if (final_url) |resolved| resolved.free(self.allocator);
        var document = try self.fetchNavigationDocumentWithReferrerPolicy(
            iframe_url,
            page_url.*,
            null,
            &final_url,
            parent.referrer_policy,
        );
        defer document.deinit(self.allocator);
        const response = document.response;

        const final_destination: ?*const Url = if (final_url) |*resolved| resolved else null;
        if (!iframeNavigationAllowed(parent, page_url, &iframe_url, final_destination)) {
            std.log.warn("Blocked redirected iframe {s} due to CSP", .{src});
            return error.IframeRedirectBlockedByCsp;
        }

        if (!document.certificate_error) {
            try self.recordSuccessfulNavigation(&iframe_url, &final_url);
        }

        const frame = try parent.allocator.create(Frame);
        frame.* = Frame.init(parent.allocator, parent.tab, parent, iframe_node);
        frame.certificate_error = document.certificate_error;
        frame.referrer_policy = response.referrer_policy;
        errdefer {
            frame.deinit();
            parent.allocator.destroy(frame);
        }
        parent.tab.registerFrame(frame);
        if (iframeViewportFromNode(iframe_node)) |viewport| {
            frame.viewport_width = viewport.width;
            frame.viewport_height = viewport.height;
        }

        const frame_url_ptr = try parent.allocator.create(Url);
        frame_url_ptr.* = iframe_url;
        frame.current_url = frame_url_ptr;
        frame.current_url_owned = true;
        url_owned = false;

        frame.clearAllowedOrigins();
        if (response.csp_header) |hdr| {
            frame.applyContentSecurityPolicy(hdr, iframe_url) catch |err| {
                std.log.warn("Failed to apply iframe CSP: {}", .{err});
            };
        }

        const raw_body = response.body;
        const body_text = try decodeUtf8Replace(self.allocator, raw_body);

        var body_text_owned = true;
        errdefer if (body_text_owned) self.allocator.free(body_text);

        var html_parser = try HTMLParser.init(self.allocator, body_text);
        defer html_parser.deinit(self.allocator);

        frame.current_node = try html_parser.parse();
        parser.fixParentPointers(&frame.current_node.?, null);
        try self.annotateVisitedLinks(&frame.current_node.?, frame_url_ptr);
        frame.current_html_source = body_text;
        body_text_owned = false;

        frame.js_context = try parent.tab.getJs(frame_url_ptr);
        if (frame.js_context) |ctx| {
            self.attachJsCallbacks(parent.tab, frame, ctx);
        }
        var parent_window_id: ?u32 = null;
        if (frame.current_url) |child_url_ptr| {
            if (page_url.*.sameOrigin(child_url_ptr.*) or
                (std.mem.eql(u8, page_url.*.scheme, "file") and std.mem.eql(u8, child_url_ptr.*.scheme, "file")))
            {
                parent_window_id = parent.window_id;
            }
        }
        parent.tab.setParentWindow(frame.window_id, parent_window_id);
        if (frame.js_context) |ctx| {
            if (parent_window_id != null and parent.js_context != null and parent.js_context == ctx) {
                ctx.setParentWindow(frame.window_id, parent_window_id);
            } else {
                ctx.setParentWindow(frame.window_id, null);
            }
        }

        var node_list = std.ArrayList(*parser.Node).empty;
        defer node_list.deinit(self.allocator);
        try parser.treeToList(self.allocator, &frame.current_node.?, &node_list);

        self.loadImages(frame, frame_url_ptr, node_list.items) catch |err| {
            std.log.warn("Failed to load iframe images: {}", .{err});
        };

        _ = self.scheduleDocumentScripts(parent.tab, frame, frame_url_ptr, node_list.items);

        var new_css_texts = std.ArrayList([]const u8).empty;
        defer {
            for (new_css_texts.items) |css_text| self.allocator.free(css_text);
            new_css_texts.deinit(self.allocator);
        }

        var all_rules = std.ArrayList(CSSParser.CSSRule).empty;
        const default_rules_count = self.default_style_sheet_rules.len;
        defer {
            for (all_rules.items) |*rule| {
                if (rule.owned) {
                    rule.deinit(self.allocator);
                }
            }
            all_rules.deinit(self.allocator);
        }

        for (self.default_style_sheet_rules) |rule| {
            try all_rules.append(self.allocator, rule);
        }

        try self.appendDocumentStylesheets(
            frame,
            frame_url_ptr,
            node_list.items,
            &new_css_texts,
            &all_rules,
        );

        std.mem.sort(CSSParser.CSSRule, all_rules.items, {}, struct {
            fn lessThan(_: void, a: CSSParser.CSSRule, b: CSSParser.CSSRule) bool {
                return a.cascadePriority() < b.cascadePriority();
            }
        }.lessThan);

        frame.rules.deinit(self.allocator);
        frame.css_texts.deinit(self.allocator);
        frame.default_rules_count = default_rules_count;
        frame.rules = all_rules;
        all_rules = .empty;
        frame.css_texts = new_css_texts;
        new_css_texts = .empty;

        try parser.style(self.allocator, &frame.current_node.?, frame.rules.items);
        try self.layoutTabNodes(frame, true);
        try parent.children.append(parent.allocator, frame);
    }

    fn scheduleScriptTask(
        self: *Browser,
        tab: *Tab,
        frame: *Frame,
        page_url: *Url,
        src: []const u8,
    ) !void {
        if (!frame.js_render_context_initialized) return;
        std.log.info("Loading script: {s}", .{src});

        const src_copy = try self.allocator.alloc(u8, src.len);
        @memcpy(src_copy, src);
        var src_copy_owned = false;
        defer if (!src_copy_owned) self.allocator.free(src_copy);

        var script_url = try page_url.*.resolve(self.allocator, src);
        var url_owned = true;
        defer if (url_owned) script_url.free(self.allocator);

        if (!frame.allowedRequest(script_url, page_url)) {
            std.log.warn("Blocked script {s} due to CSP", .{src});
            return;
        }

        const script_response = self.fetchBodyWithReferrerPolicy(
            script_url,
            page_url.*,
            null,
            frame.referrer_policy,
        ) catch |err| {
            std.log.warn("Failed to load script {s}: {}", .{ src, err });
            return;
        };
        defer if (script_response.csp_header) |hdr| self.allocator.free(hdr);

        const script_raw = script_response.body;
        const raw_owned = !std.mem.eql(u8, script_url.scheme, "data") and !std.mem.eql(u8, script_url.scheme, "about");
        defer if (raw_owned) self.allocator.free(script_raw);
        const body_copy = try decodeUtf8Replace(self.allocator, script_raw);
        var body_copy_owned = false;
        defer if (!body_copy_owned) self.allocator.free(body_copy);

        const ctx = try ScriptTaskContext.create(
            self.allocator,
            self,
            tab,
            DocumentHandle.fromFrame(frame),
            src_copy,
            script_url,
            body_copy,
        );
        src_copy_owned = true;
        body_copy_owned = true;
        url_owned = false;
        errdefer ctx.destroy();

        const task_instance = Task.init(
            ctx.toOpaque(),
            ScriptTaskContext.runOpaque,
            ScriptTaskContext.cleanupOpaque,
        );
        try tab.task_runner.schedule(task_instance);
    }

    fn collectInlineScriptText(self: *Browser, node: *Node) ?[]u8 {
        switch (node.*) {
            .element => |e| {
                if (!std.mem.eql(u8, e.tag, "script")) return null;
                var buffer = std.ArrayList(u8).empty;
                errdefer buffer.deinit(self.allocator);
                for (e.children.items) |*child| {
                    switch (child.*) {
                        .text => |t| buffer.appendSlice(self.allocator, t.text) catch return null,
                        .element => {},
                    }
                }
                if (buffer.items.len == 0) {
                    buffer.deinit(self.allocator);
                    return null;
                }
                return buffer.toOwnedSlice(self.allocator) catch {
                    buffer.deinit(self.allocator);
                    return null;
                };
            },
            else => return null,
        }
    }

    /// Queue each attached classic script at most once. `script_started` is
    /// stored on the DOM element rather than in a transient node list so the
    /// guarantee survives removeChild followed by re-attachment. Marking is
    /// committed only after scheduling succeeds; allocation failures remain
    /// retryable on the next resource scan.
    fn scheduleDocumentScripts(
        self: *Browser,
        tab: *Tab,
        frame: *Frame,
        page_url: *Url,
        nodes: []*Node,
    ) bool {
        var all_started = true;
        for (nodes) |node| {
            const element = switch (node.*) {
                .element => |*value| value,
                .text => continue,
            };
            if (!std.mem.eql(u8, element.tag, "script") or element.script_started) continue;

            if (element.attributes) |attrs| {
                if (attrs.get("src")) |src| {
                    self.scheduleScriptTask(tab, frame, page_url, src) catch |err| {
                        std.log.warn("Failed to schedule script {s}: {}", .{ src, err });
                        all_started = false;
                        continue;
                    };
                    element.script_started = true;
                    continue;
                }
            }

            if (self.collectInlineScriptText(node)) |script_body| {
                defer self.allocator.free(script_body);
                self.scheduleInlineScriptTask(tab, frame, page_url, script_body) catch |err| {
                    std.log.warn("Failed to schedule inline script: {}", .{err});
                    all_started = false;
                    continue;
                };
            }
            element.script_started = true;
        }
        return all_started;
    }

    /// Rebuild an author stylesheet generation from the currently attached
    /// DOM. Rules and their borrowed text buffers are staged and transferred
    /// together, so removing a `<link>` retires its rules without creating a
    /// dangling CSS string borrow.
    fn replaceFrameStylesheets(
        self: *Browser,
        frame: *Frame,
        page_url: *Url,
        nodes: []*Node,
    ) !void {
        var new_css_texts = std.ArrayList([]const u8).empty;
        defer {
            for (new_css_texts.items) |css_text| self.allocator.free(css_text);
            new_css_texts.deinit(self.allocator);
        }

        var new_rules = std.ArrayList(CSSParser.CSSRule).empty;
        defer {
            for (new_rules.items) |*rule| {
                if (rule.owned) rule.deinit(self.allocator);
            }
            new_rules.deinit(self.allocator);
        }

        for (self.default_style_sheet_rules) |rule| {
            try new_rules.append(self.allocator, rule);
        }
        try self.appendDocumentStylesheets(
            frame,
            page_url,
            nodes,
            &new_css_texts,
            &new_rules,
        );

        std.mem.sort(CSSParser.CSSRule, new_rules.items, {}, struct {
            fn lessThan(_: void, a: CSSParser.CSSRule, b: CSSParser.CSSRule) bool {
                return a.cascadePriority() < b.cascadePriority();
            }
        }.lessThan);

        // Rules borrow the old CSS buffers, so destroy them before freeing the
        // buffers and then atomically install the staged generation.
        for (frame.rules.items) |*rule| {
            if (rule.owned) rule.deinit(self.allocator);
        }
        frame.rules.deinit(self.allocator);
        for (frame.css_texts.items) |css_text| self.allocator.free(css_text);
        frame.css_texts.deinit(self.allocator);

        frame.default_rules_count = self.default_style_sheet_rules.len;
        frame.rules = new_rules;
        new_rules = .empty;
        frame.css_texts = new_css_texts;
        new_css_texts = .empty;
    }

    /// Refresh resources after an attached structural DOM mutation. This is
    /// called only by the serialized tab worker, after the mutation host call
    /// has returned, so fetching and queueing cannot re-enter Kiesel.
    pub fn refreshFrameResources(self: *Browser, frame: *Frame) !void {
        if (!frame.resources_dirty) return;
        const root = if (frame.current_node) |*node| node else {
            frame.resources_dirty = false;
            return;
        };
        const page_url = frame.current_url orelse {
            frame.resources_dirty = false;
            return;
        };

        frame.resources_dirty = false;
        errdefer frame.resources_dirty = true;

        var nodes = std.ArrayList(*Node).empty;
        defer nodes.deinit(self.allocator);
        try parser.treeToList(self.allocator, root, &nodes);

        const scripts_started = self.scheduleDocumentScripts(frame.tab, frame, page_url, nodes.items);
        try self.replaceFrameStylesheets(frame, page_url, nodes.items);
        if (!scripts_started) frame.resources_dirty = true;
    }

    /// Parse one owned document stylesheet into staged frame storage. The
    /// caller retains ownership of `css_text` on error and transfers it to
    /// `css_texts` only after this function succeeds.
    fn appendDocumentStylesheetRules(
        self: *Browser,
        css_text: []const u8,
        prefers_dark: bool,
        css_texts: *std.ArrayList([]const u8),
        rules: *std.ArrayList(CSSParser.CSSRule),
    ) !void {
        var css_parser = try CSSParser.init(self.allocator, css_text, prefers_dark);
        defer css_parser.deinit(self.allocator);

        const parsed_rules = try css_parser.parse(self.allocator);
        var parsed_rules_owned = true;
        defer {
            if (parsed_rules_owned) {
                for (parsed_rules) |*rule| rule.deinit(self.allocator);
            }
            self.allocator.free(parsed_rules);
        }

        // Reserve both destinations before transferring either half of the
        // generation. Every parsed rule borrows from css_text.
        try css_texts.ensureUnusedCapacity(self.allocator, 1);
        try rules.ensureUnusedCapacity(self.allocator, parsed_rules.len);
        css_texts.appendAssumeCapacity(css_text);
        for (parsed_rules) |rule| rules.appendAssumeCapacity(rule);
        parsed_rules_owned = false;
    }

    /// Load author stylesheets in DOM order. Inline `<style>` text is copied
    /// into the same frame-owned backing store as decoded external CSS so rule
    /// rebuilding and retirement do not depend on DOM string lifetimes.
    fn appendDocumentStylesheets(
        self: *Browser,
        frame: *Frame,
        page_url: *Url,
        nodes: []*Node,
        css_texts: *std.ArrayList([]const u8),
        rules: *std.ArrayList(CSSParser.CSSRule),
    ) !void {
        for (nodes) |node| {
            const element = switch (node.*) {
                .element => |*value| value,
                .text => continue,
            };

            if (std.mem.eql(u8, element.tag, "style")) {
                const css_text = (try parser.collectInlineStyleText(self.allocator, node)) orelse continue;
                var css_text_owned = true;
                defer if (css_text_owned) self.allocator.free(css_text);

                self.appendDocumentStylesheetRules(
                    css_text,
                    frame.tab.accessibility.prefers_dark,
                    css_texts,
                    rules,
                ) catch |err| {
                    std.log.warn("Failed to parse inline stylesheet: {}", .{err});
                    continue;
                };
                css_text_owned = false;
                continue;
            }

            if (!std.mem.eql(u8, element.tag, "link")) continue;
            const attrs = element.attributes orelse continue;
            const rel = attrs.get("rel") orelse continue;
            const href = attrs.get("href") orelse continue;
            if (!std.mem.eql(u8, rel, "stylesheet")) continue;

            std.log.info("Loading stylesheet: {s}", .{href});
            const stylesheet_url = page_url.*.resolve(self.allocator, href) catch |err| {
                std.log.warn("Failed to resolve stylesheet URL {s}: {}", .{ href, err });
                continue;
            };
            defer stylesheet_url.free(self.allocator);

            if (!frame.allowedRequest(stylesheet_url, page_url)) {
                std.log.warn("Blocked stylesheet {s} due to CSP", .{href});
                continue;
            }

            const css_response = self.fetchBodyWithReferrerPolicy(
                stylesheet_url,
                page_url.*,
                null,
                frame.referrer_policy,
            ) catch |err| {
                std.log.warn("Failed to load stylesheet {s}: {}", .{ href, err });
                continue;
            };
            defer if (css_response.csp_header) |header| self.allocator.free(header);

            const css_raw = css_response.body;
            const raw_owned = !std.mem.eql(u8, stylesheet_url.scheme, "data") and
                !std.mem.eql(u8, stylesheet_url.scheme, "about");
            defer if (raw_owned) self.allocator.free(css_raw);

            const css_text = try decodeUtf8Replace(self.allocator, css_raw);
            var css_text_owned = true;
            defer if (css_text_owned) self.allocator.free(css_text);

            self.appendDocumentStylesheetRules(
                css_text,
                frame.tab.accessibility.prefers_dark,
                css_texts,
                rules,
            ) catch |err| {
                std.log.warn("Failed to parse stylesheet {s}: {}", .{ href, err });
                continue;
            };
            css_text_owned = false;
        }
    }

    fn scheduleInlineScriptTask(
        self: *Browser,
        tab: *Tab,
        frame: *Frame,
        page_url: *Url,
        script_body: []const u8,
    ) !void {
        if (!frame.js_render_context_initialized) return;

        var script_url: Url = undefined;
        var url_owned = true;
        const label = if (std.mem.eql(u8, page_url.*.scheme, "data")) blk: {
            script_url = try Url.blank(self.allocator);
            break :blk try self.allocator.dupe(u8, "inline:data");
        } else blk: {
            var url_buf: [2048]u8 = undefined;
            const url_str = page_url.*.toString(&url_buf) catch |err| {
                std.log.warn("Failed to format inline script URL: {}", .{err});
                return;
            };
            const url_copy = try self.allocator.dupe(u8, url_str);
            defer self.allocator.free(url_copy);
            script_url = try Url.init(self.allocator, url_copy);
            break :blk try std.fmt.allocPrint(self.allocator, "inline:{s}", .{url_str});
        };
        var label_owned = false;
        defer if (!label_owned) self.allocator.free(label);

        const body_copy = try self.allocator.alloc(u8, script_body.len);
        @memcpy(body_copy, script_body);
        var body_owned = false;
        defer if (!body_owned) self.allocator.free(body_copy);

        const ctx = try ScriptTaskContext.create(
            self.allocator,
            self,
            tab,
            DocumentHandle.fromFrame(frame),
            label,
            script_url,
            body_copy,
        );
        label_owned = true;
        body_owned = true;
        url_owned = false;
        errdefer ctx.destroy();

        const task_instance = Task.init(
            ctx.toOpaque(),
            ScriptTaskContext.runOpaque,
            ScriptTaskContext.cleanupOpaque,
        );
        try tab.task_runner.schedule(task_instance);
    }

    fn scheduleSetTimeoutTask(
        self: *Browser,
        tab: *Tab,
        js_context: *JsRenderContext,
        handle: u32,
        delay_ms: u32,
    ) !void {
        if (tab.isShuttingDown() or js_context.js_context == null) return;
        const document = DocumentHandle{
            .window_id = js_context.window_id,
            .generation = js_context.currentGeneration(),
        };

        const thread_ctx = try SetTimeoutThreadContext.create(
            self.allocator,
            self,
            tab,
            document,
            handle,
            delay_ms,
        );

        tab.retainAsyncThread();
        const thread = std.Thread.spawn(.{}, runSetTimeoutThread, .{thread_ctx}) catch |err| {
            thread_ctx.destroy();
            tab.releaseAsyncThread();
            return err;
        };
        _ = thread.setName(self.io, "SetTimeout thread") catch |err| {
            std.log.warn("Failed to name setTimeout thread: {}", .{err});
        };
        thread.detach();
    }

    pub fn scheduleAnimationFrame(self: *Browser) void {
        self.lock.lock();
        if (self.shutting_down or self.animation_timer_active or !self.needs_animation_frame or self.activeTab() == null) {
            self.lock.unlock();
            return;
        }
        const tab = self.activeTab().?;
        self.animation_timer_active = true;
        self.needs_animation_frame = false;
        tab.retainAsyncThread();
        self.lock.unlock();

        const ctx = AnimationTimerContext.create(self, tab) catch |err| {
            std.log.warn("Failed to allocate animation timer context: {}", .{err});
            self.lock.lock();
            self.animation_timer_active = false;
            self.needs_animation_frame = true;
            self.lock.unlock();
            tab.releaseAsyncThread();
            return;
        };

        const thread = std.Thread.spawn(.{}, runAnimationTimerThread, .{ctx}) catch |err| {
            std.log.warn("Failed to spawn animation timer thread: {}", .{err});
            ctx.destroy();
            self.lock.lock();
            self.animation_timer_active = false;
            self.needs_animation_frame = true;
            self.lock.unlock();
            tab.releaseAsyncThread();
            return;
        };
        _ = thread.setName(self.io, "Animation timer thread") catch |err| {
            std.log.warn("Failed to name animation timer thread: {}", .{err});
        };
        thread.detach();
    }

    fn scheduleAsyncXhr(
        self: *Browser,
        tab: *Tab,
        js_context: *JsRenderContext,
        resolved_url: Url,
        referrer: ?Url,
        referrer_policy: url_module.ReferrerPolicy,
        payload: ?[]const u8,
        handle: u32,
    ) !void {
        if (tab.isShuttingDown() or js_context.js_context == null) return;

        var resolved_copy = try resolved_url.clone(self.allocator);
        var resolved_copy_owned = true;
        defer if (resolved_copy_owned) resolved_copy.free(self.allocator);

        var referrer_copy: ?Url = null;
        var referrer_copy_owned = false;
        if (referrer) |source| {
            referrer_copy = try source.clone(self.allocator);
            referrer_copy_owned = true;
        }
        defer if (referrer_copy_owned) referrer_copy.?.free(self.allocator);

        const ctx = try XhrThreadContext.create(
            self.allocator,
            self,
            tab,
            .{
                .window_id = js_context.window_id,
                .generation = js_context.currentGeneration(),
            },
            resolved_copy,
            referrer_copy,
            referrer_policy,
            payload,
            handle,
        );
        resolved_copy_owned = false;
        referrer_copy_owned = false;

        tab.retainAsyncThread();
        const thread = std.Thread.spawn(.{}, runXhrThread, .{ctx}) catch |err| {
            ctx.destroy();
            tab.releaseAsyncThread();
            return err;
        };
        _ = thread.setName(self.io, "XHR thread") catch |err| {
            std.log.warn("Failed to name XHR thread: {}", .{err});
        };
        thread.detach();
    }

    fn rebuildTabStyleRules(self: *Browser, tab: *Tab) !void {
        const frame = tab.root_frame orelse return;
        const default_rules_count = self.default_style_sheet_rules.len;

        var new_rules = std.ArrayList(CSSParser.CSSRule).empty;
        defer {
            for (new_rules.items) |*rule| {
                if (rule.owned) rule.deinit(self.allocator);
            }
            new_rules.deinit(self.allocator);
        }

        for (self.default_style_sheet_rules) |rule| {
            try new_rules.append(self.allocator, rule);
        }

        for (frame.css_texts.items) |css_text| {
            var css_parser = try CSSParser.init(self.allocator, css_text, tab.accessibility.prefers_dark);
            defer css_parser.deinit(self.allocator);

            const parsed_rules = css_parser.parse(self.allocator) catch |err| {
                std.log.warn("Failed to parse stylesheet on rebuild: {}", .{err});
                continue;
            };
            var parsed_rules_owned = true;
            defer {
                if (parsed_rules_owned) {
                    for (parsed_rules) |*rule| rule.deinit(self.allocator);
                }
                self.allocator.free(parsed_rules);
            }

            try new_rules.ensureUnusedCapacity(self.allocator, parsed_rules.len);
            for (parsed_rules) |rule| {
                new_rules.appendAssumeCapacity(rule);
            }
            parsed_rules_owned = false;
        }

        std.mem.sort(CSSParser.CSSRule, new_rules.items, {}, struct {
            fn lessThan(_: void, a: CSSParser.CSSRule, b: CSSParser.CSSRule) bool {
                return a.cascadePriority() < b.cascadePriority();
            }
        }.lessThan);

        for (frame.rules.items) |*rule| {
            if (rule.owned) rule.deinit(self.allocator);
        }
        frame.rules.deinit(self.allocator);
        frame.rules = new_rules;
        new_rules = .empty;
        frame.default_rules_count = default_rules_count;
    }

    // Layout a tab's HTML nodes with the tree-based layout
    pub fn layoutTabNodes(self: *Browser, frame: *Frame, force_paint: bool) !void {
        if (frame.current_node == null) {
            return error.NoNodeToLayout;
        }

        self.layout_engine.accessibility = frame.tab.accessibility;
        const saved_window_width = self.layout_engine.window_width;
        const saved_window_height = self.layout_engine.window_height;
        defer {
            self.layout_engine.window_width = saved_window_width;
            self.layout_engine.window_height = saved_window_height;
        }
        if (frame.parent != null and frame.viewport_width > 0) {
            self.layout_engine.window_width = self.scalePxWithZoom(frame.viewport_width, frame.tab.accessibility.zoom);
        } else {
            self.layout_engine.window_width = frame.tab.tab_width;
        }
        if (frame.parent != null and frame.viewport_height > 0) {
            self.layout_engine.window_height = self.scalePxWithZoom(frame.viewport_height, frame.tab.accessibility.zoom);
        } else {
            self.layout_engine.window_height = frame.tab.tab_height;
        }

        const scheme_dark = self.layout_engine.resolveColorScheme("light dark");
        self.layout_engine.color_scheme_dark = scheme_dark;
        self.layout_engine.document_color_scheme_dark = scheme_dark;

        var did_layout = false;
        if (frame.document_layout == null) {
            // Create and layout the document tree the first time
            frame.document_layout = try self.layout_engine.buildDocument(&frame.current_node.?);
            did_layout = true;
        } else {
            // Layout on subsequent frames - only if needed
            const doc = frame.document_layout.?;
            if (doc.layoutNeeded()) {
                // doc.layout can destroy/rebuild BlockLayout descendants.
                // Retire their borrowed provenance before entering it.
                frame.retireDisplayList();
                try doc.layout(self.layout_engine);
                did_layout = true;
            }
        }
        // Repaint if layout ran or paint was requested
        if (did_layout or force_paint) {
            // Paint the document to produce draw commands
            frame.retireDisplayList();
            frame.display_list = try self.layout_engine.paintDocument(frame.document_layout.?);
            try frame.updateHitTestBounds(self.layout_engine);
        }

        var focus_items = std.ArrayList(DisplayItem).empty;
        defer focus_items.deinit(self.allocator);
        const focus_color = Color{ .r = 0x3b, .g = 0x82, .b = 0xf6, .a = 0xff };
        const highlight_color = Color{ .r = 0xf5, .g = 0x9e, .b = 0x0b, .a = 0xff };

        if (frame.focus) |focus_node| {
            for (self.layout_engine.focus_bounds.items) |entry| {
                if (entry.node == focus_node) {
                    self.appendOutline(&focus_items, focus_color, entry.bounds) catch |err| {
                        std.log.warn("Failed to append focus outline: {}", .{err});
                    };
                }
            }
        }

        if (frame.tab.accessibility_highlight) |highlight_node| {
            if (highlight_node.dom_node) |dom| {
                for (self.layout_engine.focus_bounds.items) |entry| {
                    if (entry.node == dom) {
                        self.appendOutline(&focus_items, highlight_color, entry.bounds) catch |err| {
                            std.log.warn("Failed to append highlight outline: {}", .{err});
                        };
                    }
                }
            }
        }

        if (focus_items.items.len > 0 and frame.display_list != null) {
            const old_list = frame.display_list.?;
            var combined = std.ArrayList(DisplayItem).empty;
            defer combined.deinit(self.allocator);
            try combined.appendSlice(self.allocator, old_list);
            try combined.appendSlice(self.allocator, focus_items.items);
            frame.display_list = try combined.toOwnedSlice(self.allocator);
            // Only free the old container; the items (and their children) are now owned by the new list.
            self.allocator.free(old_list);
        }

        // Update content height from the layout engine
        frame.content_height = self.layout_engine.content_height;

        frame.tab.buildAccessibilityTree() catch |err| {
            std.log.warn("Failed to build accessibility tree: {}", .{err});
        };
    }

    /// Build composited layers from the display list
    /// Returns true if layers were rebuilt, false if using cached layers
    pub fn composite(self: *Browser) !bool {
        if (self.active_tab_display_list == null) return false;

        // Clear existing layers (they'll be rebuilt)
        for (self.composited_layers.items) |*layer| {
            layer.deinit(self.allocator);
        }
        self.composited_layers.items.len = 0;

        // Walk the display list and create layers for blend items
        for (self.active_tab_display_list.?) |item| {
            try self.compositeItem(item);
        }

        // Log layer count for optimization verification
        std.log.debug("Compositing complete: {} layers created", .{self.composited_layers.items.len});

        return true;
    }

    fn appendOutline(self: *Browser, items: *std.ArrayList(DisplayItem), color: Color, bounds: Layout.Bounds) !void {
        const padding: i32 = 2;
        const left = bounds.x - padding;
        const top = bounds.y - padding;
        const right = bounds.x + bounds.width + padding;
        const bottom = bounds.y + bounds.height + padding;
        try items.append(self.allocator, .{
            .line = .{
                .x1 = left,
                .y1 = top,
                .x2 = right,
                .y2 = top,
                .color = color,
                .thickness = 1,
            },
        });
        try items.append(self.allocator, .{
            .line = .{
                .x1 = right,
                .y1 = top,
                .x2 = right,
                .y2 = bottom,
                .color = color,
                .thickness = 1,
            },
        });
        try items.append(self.allocator, .{
            .line = .{
                .x1 = right,
                .y1 = bottom,
                .x2 = left,
                .y2 = bottom,
                .color = color,
                .thickness = 1,
            },
        });
        try items.append(self.allocator, .{
            .line = .{
                .x1 = left,
                .y1 = bottom,
                .x2 = left,
                .y2 = top,
                .color = color,
                .thickness = 1,
            },
        });
    }

    /// Recursively process a display item for compositing
    fn compositeItem(self: *Browser, item: DisplayItem) !void {
        switch (item) {
            .blend => |blend_item| {
                // Use the pre-computed needs_compositing flag
                const needs_layer = blend_item.needs_compositing;

                if (needs_layer) {
                    const is_dst_in = if (blend_item.blend_mode) |mode|
                        std.mem.eql(u8, mode, "dst_in")
                    else
                        false;

                    if (is_dst_in) {
                        const cloned = try self.cloneDisplayItem(item);
                        var cloned_owned = true;
                        errdefer if (cloned_owned) {
                            var cloned_items = [_]DisplayItem{cloned};
                            DisplayItem.freeItems(self.allocator, &cloned_items);
                        };

                        const layer_items = try self.allocator.alloc(DisplayItem, 1);
                        layer_items[0] = cloned;
                        cloned_owned = false;

                        const bounds = self.getDisplayItemBounds(item);
                        const layer_blend_mode = if (cloned == .blend) cloned.blend.blend_mode else blend_item.blend_mode;

                        var layer = CompositedLayer.init(
                            layer_items,
                            bounds,
                            blend_item.opacity,
                            layer_blend_mode,
                            blend_item.node,
                        );
                        var layer_owned = true;
                        errdefer if (layer_owned) layer.deinit(self.allocator);
                        try self.composited_layers.append(self.allocator, layer);
                        layer_owned = false;
                        return;
                    }

                    // Flatten the subtree to collect all non-composited items
                    var flattened = std.ArrayList(DisplayItem).empty;
                    defer flattened.deinit(self.allocator);
                    errdefer DisplayItem.freeItems(self.allocator, flattened.items);
                    try self.flattenSubtree(blend_item.children, &flattened);

                    // flattenSubtree deep-copies every owning command, so the
                    // resulting slice can move directly into the layer.
                    const flattened_items = try flattened.toOwnedSlice(self.allocator);
                    var flattened_items_owned = true;
                    errdefer if (flattened_items_owned) DisplayItem.freeList(self.allocator, flattened_items);

                    // Calculate bounds from flattened children
                    var bounds = Rect{ .left = std.math.maxInt(i32), .top = std.math.maxInt(i32), .right = std.math.minInt(i32), .bottom = std.math.minInt(i32) };
                    for (flattened_items) |child| {
                        const child_bounds = self.getDisplayItemBounds(child);
                        bounds.left = @min(bounds.left, child_bounds.left);
                        bounds.top = @min(bounds.top, child_bounds.top);
                        bounds.right = @max(bounds.right, child_bounds.right);
                        bounds.bottom = @max(bounds.bottom, child_bounds.bottom);
                    }

                    // Keep one layer per effect wrapper. Effect subtrees are
                    // ordered groups (filter, then clip, then opacity/blend),
                    // and merging neighboring groups would let a dst_in mask
                    // or blur consume pixels belonging to another element.
                    var layer = CompositedLayer.init(
                        flattened_items,
                        bounds,
                        blend_item.opacity,
                        blend_item.blend_mode,
                        blend_item.node,
                    );
                    flattened_items_owned = false;
                    var layer_owned = true;
                    errdefer if (layer_owned) layer.deinit(self.allocator);
                    try self.composited_layers.append(self.allocator, layer);
                    layer_owned = false;
                } else {
                    // No layer needed, recurse into children
                    for (blend_item.children) |child| {
                        try self.compositeItem(child);
                    }
                }
            },
            .transform => |transform_item| {
                // Recurse into transform children - they may contain composited blends
                for (transform_item.children) |child| {
                    try self.compositeItem(child);
                }
            },
            else => {
                // Primitive items don't need compositing decisions
            },
        }
    }

    const CloneError = error{OutOfMemory};

    fn cloneDisplayItem(self: *Browser, item: DisplayItem) CloneError!DisplayItem {
        switch (item) {
            .blend => |blend_item| {
                const children = try self.cloneDisplayItemList(blend_item.children);
                errdefer DisplayItem.freeList(self.allocator, children);
                const mode_copy = if (blend_item.blend_mode) |mode| blk: {
                    const dup = try self.allocator.alloc(u8, mode.len);
                    @memcpy(dup, mode);
                    break :blk dup;
                } else null;
                return .{
                    .blend = .{
                        .opacity = blend_item.opacity,
                        .blend_mode = mode_copy,
                        .blur_radius = blend_item.blur_radius,
                        .hit_clip = blend_item.hit_clip,
                        .children = children,
                        .node = blend_item.node,
                        .parent = null,
                        .needs_compositing = blend_item.needs_compositing,
                        .source = blend_item.source,
                    },
                };
            },
            .transform => |transform_item| {
                const children = try self.cloneDisplayItemList(transform_item.children);
                return .{
                    .transform = .{
                        .translate_x = transform_item.translate_x,
                        .translate_y = transform_item.translate_y,
                        .children = children,
                        .node = transform_item.node,
                        .source = transform_item.source,
                    },
                };
            },
            else => return item,
        }
    }

    fn cloneDisplayItemList(self: *Browser, items: []DisplayItem) CloneError![]DisplayItem {
        const copy = try self.allocator.alloc(DisplayItem, items.len);
        var filled: usize = 0;
        errdefer {
            if (filled > 0) {
                DisplayItem.freeItems(self.allocator, copy[0..filled]);
            }
            self.allocator.free(copy);
        }
        for (items, 0..) |item, idx| {
            copy[idx] = try self.cloneDisplayItem(item);
            filled = idx + 1;
        }
        return copy;
    }

    /// Flatten a subtree of display items by recursively expanding non-composited blends.
    /// This collects primitives into an independently owned list for efficient
    /// rasterization. Owning commands are cloned so failure cleanup never
    /// aliases the browser's committed display list.
    fn flattenSubtree(self: *Browser, items: []DisplayItem, result: *std.ArrayList(DisplayItem)) !void {
        for (items) |item| {
            switch (item) {
                .blend => |blend_item| {
                    if (blend_item.needs_compositing) {
                        // Composited blends stay as-is (they'll create their own layer)
                        const cloned = try self.cloneDisplayItem(item);
                        var cloned_owned = true;
                        errdefer if (cloned_owned) {
                            var cloned_items = [_]DisplayItem{cloned};
                            DisplayItem.freeItems(self.allocator, &cloned_items);
                        };
                        try result.append(self.allocator, cloned);
                        cloned_owned = false;
                    } else {
                        // Non-composited blends are flattened - recurse into children
                        try self.flattenSubtree(blend_item.children, result);
                    }
                },
                .transform => |transform_item| {
                    // Transforms need to be preserved to apply translation during rendering
                    // Recursively flatten children but wrap them in the transform
                    var flattened_children = std.ArrayList(DisplayItem).empty;
                    defer flattened_children.deinit(self.allocator);
                    errdefer DisplayItem.freeItems(self.allocator, flattened_children.items);
                    try self.flattenSubtree(transform_item.children, &flattened_children);

                    if (flattened_children.items.len > 0) {
                        // Move the independently owned children into the new
                        // transform and guard that move until append succeeds.
                        const children_copy = try flattened_children.toOwnedSlice(self.allocator);
                        var children_owned = true;
                        errdefer if (children_owned) DisplayItem.freeList(self.allocator, children_copy);
                        try result.append(self.allocator, .{
                            .transform = .{
                                .translate_x = transform_item.translate_x,
                                .translate_y = transform_item.translate_y,
                                .children = children_copy,
                                .node = transform_item.node,
                                .source = transform_item.source,
                            },
                        });
                        children_owned = false;
                    }
                },
                else => {
                    // Primitive items are added directly
                    try result.append(self.allocator, item);
                },
            }
        }
    }

    fn displayItemsBounds(self: *Browser, items: []const DisplayItem) ?Rect {
        if (items.len == 0) return null;
        var bounds = self.getDisplayItemBounds(items[0]);
        for (items[1..]) |child| {
            const child_bounds = self.getDisplayItemBounds(child);
            bounds.left = @min(bounds.left, child_bounds.left);
            bounds.top = @min(bounds.top, child_bounds.top);
            bounds.right = @max(bounds.right, child_bounds.right);
            bounds.bottom = @max(bounds.bottom, child_bounds.bottom);
        }
        return bounds;
    }

    fn blurOutset(self: *Browser, radius: f64) i32 {
        const zoom = if (self.active_tab_zoom > 0) self.active_tab_zoom else 1.0;
        return @intCast(blurKernelRadius(radius * @as(f64, zoom)));
    }

    /// Get the bounding rect of a display item in device/document coordinates.
    fn getDisplayItemBounds(self: *Browser, item: DisplayItem) Rect {
        return switch (item) {
            .glyph => |g| Rect{
                .left = self.scalePx(g.x),
                .top = self.scalePx(g.y),
                .right = self.scalePx(g.x) + g.glyph.w,
                .bottom = self.scalePx(g.y) + g.glyph.h,
            },
            .rect => |r| Rect{
                .left = self.scalePx(r.x1),
                .top = self.scalePx(r.y1),
                .right = self.scalePx(r.x2),
                .bottom = self.scalePx(r.y2),
            },
            .image => |img| Rect{
                .left = self.scalePx(img.x1),
                .top = self.scalePx(img.y1),
                .right = self.scalePx(img.x2),
                .bottom = self.scalePx(img.y2),
            },
            .iframe => |iframe_item| Rect{
                .left = self.scalePx(iframe_item.rect.left),
                .top = self.scalePx(iframe_item.rect.top),
                .right = self.scalePx(iframe_item.rect.right),
                .bottom = self.scalePx(iframe_item.rect.bottom),
            },
            .rounded_rect => |r| Rect{
                .left = self.scalePx(r.x1),
                .top = self.scalePx(r.y1),
                .right = self.scalePx(r.x2),
                .bottom = self.scalePx(r.y2),
            },
            .line => |l| Rect{
                .left = self.scalePx(@min(l.x1, l.x2)),
                .top = self.scalePx(@min(l.y1, l.y2)),
                .right = self.scalePx(@max(l.x1, l.x2)) + self.scalePx(l.thickness),
                .bottom = self.scalePx(@max(l.y1, l.y2)) + self.scalePx(l.thickness),
            },
            .outline => |o| Rect{
                .left = self.scalePx(o.rect.left),
                .top = self.scalePx(o.rect.top),
                .right = self.scalePx(o.rect.right),
                .bottom = self.scalePx(o.rect.bottom),
            },
            .blend => |b| blk: {
                if (b.blend_mode) |mode| {
                    if (std.mem.eql(u8, mode, "dst_in") and b.children.len > 0) {
                        const mask_child = b.children[b.children.len - 1];
                        break :blk self.getDisplayItemBounds(mask_child);
                    }
                }
                var bounds = self.displayItemsBounds(b.children) orelse Rect{
                    .left = 0,
                    .top = 0,
                    .right = 0,
                    .bottom = 0,
                };
                if (b.blur_radius > 0.0) bounds = bounds.outset(self.blurOutset(b.blur_radius));
                break :blk bounds;
            },
            .draw_composited_layer => |dcl| dcl.layer.bounds,
            .transform => |t| blk: {
                // Get children bounds and apply translation offset
                var bounds = Rect{ .left = std.math.maxInt(i32), .top = std.math.maxInt(i32), .right = std.math.minInt(i32), .bottom = std.math.minInt(i32) };
                for (t.children) |child| {
                    const child_bounds = self.getDisplayItemBounds(child);
                    bounds.left = @min(bounds.left, child_bounds.left);
                    bounds.top = @min(bounds.top, child_bounds.top);
                    bounds.right = @max(bounds.right, child_bounds.right);
                    bounds.bottom = @max(bounds.bottom, child_bounds.bottom);
                }
                // Apply translation to get absolute bounds
                break :blk Rect{
                    .left = bounds.left + self.scalePx(t.translate_x),
                    .top = bounds.top + self.scalePx(t.translate_y),
                    .right = bounds.right + self.scalePx(t.translate_x),
                    .bottom = bounds.bottom + self.scalePx(t.translate_y),
                };
            },
        };
    }

    /// Build a draw list from composited layers
    pub fn paintDrawList(self: *Browser) !void {
        if (self.tab_draw_list.items.len > 0) {
            DisplayItem.freeItems(self.allocator, self.tab_draw_list.items);
            self.tab_draw_list.items.len = 0;
        }

        if (self.active_tab_display_list == null) return;

        // Walk the display list and emit draw commands
        var layer_index: usize = 0;
        for (self.active_tab_display_list.?) |item| {
            try self.paintItem(item, &layer_index);
        }
    }

    /// Recursively emit draw commands for an item
    fn paintItem(self: *Browser, item: DisplayItem, layer_index: *usize) !void {
        switch (item) {
            .blend => |blend_item| {
                // Use the pre-computed needs_compositing flag
                if (blend_item.needs_compositing) {
                    // Emit a DrawCompositedLayer pointing to the corresponding layer
                    if (layer_index.* < self.composited_layers.items.len) {
                        try self.tab_draw_list.append(self.allocator, .{
                            .draw_composited_layer = .{
                                .layer = &self.composited_layers.items[layer_index.*],
                            },
                        });
                        layer_index.* += 1;
                    }
                } else {
                    // No layer, emit children directly
                    for (blend_item.children) |child| {
                        try self.paintItem(child, layer_index);
                    }
                }
            },
            .transform => |transform_item| {
                // Transforms preserve their structure but recurse for composited content
                // We need to collect children and emit a transform wrapping them
                // Save original draw list length
                const original_len = self.tab_draw_list.items.len;

                // Recurse into children
                for (transform_item.children) |child| {
                    try self.paintItem(child, layer_index);
                }

                // Collect newly added items
                if (self.tab_draw_list.items.len > original_len) {
                    const new_items = self.tab_draw_list.items[original_len..];
                    const children_copy = try self.allocator.alloc(DisplayItem, new_items.len);
                    @memcpy(children_copy, new_items);

                    // Remove the newly added items
                    self.tab_draw_list.items.len = original_len;
                    var children_owned = true;
                    errdefer if (children_owned) DisplayItem.freeList(self.allocator, children_copy);

                    // Emit transform wrapping those items
                    try self.tab_draw_list.append(self.allocator, .{
                        .transform = .{
                            .translate_x = transform_item.translate_x,
                            .translate_y = transform_item.translate_y,
                            .children = children_copy,
                            .node = transform_item.node,
                            .source = transform_item.source,
                        },
                    });
                    children_owned = false;
                }
            },
            else => {
                // Primitive items go directly to the draw list
                try self.tab_draw_list.append(self.allocator, item);
            },
        }
    }

    // Raster the browser chrome to the chrome surface
    pub fn rasterChrome(self: *Browser) !void {
        // Create a temporary context for the chrome surface
        var chrome_context = z2d.Context.init(self.io, self.allocator, &self.chrome_surface);
        defer chrome_context.deinit();

        // Clear chrome surface (white background)
        chrome_context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 } } } });
        try chrome_context.moveTo(0, 0);
        try chrome_context.lineTo(@floatFromInt(self.window_width), 0);
        try chrome_context.lineTo(@floatFromInt(self.window_width), @floatFromInt(self.chrome.bottom));
        try chrome_context.lineTo(0, @floatFromInt(self.chrome.bottom));
        try chrome_context.closePath();
        try chrome_context.fill();

        // Draw chrome content
        const chrome_cmds = try self.chrome.paint(self);
        for (chrome_cmds) |item| {
            try self.drawDisplayItemZ2dContext(&chrome_context, item, 0, 1.0);
        }
    }

    // Raster tab content to surfaces (without rebuilding composite/draw lists)
    fn rasterTabSurfaces(self: *Browser) !void {
        if (self.active_tab_display_list == null) {
            self.invalidateInterestRegion();
            return;
        }

        const region = self.interestRegionForScroll(self.active_tab_scroll);
        const tab_height = region.height_px;

        if (self.tab_surface) |*existing_surface| {
            const current_width = existing_surface.getWidth();
            const current_height = existing_surface.getHeight();
            if (current_width != self.window_width or current_height != tab_height) {
                const replacement = try z2d.Surface.init(
                    .image_surface_rgba,
                    self.allocator,
                    self.window_width,
                    tab_height,
                );
                existing_surface.deinit(self.allocator);
                self.tab_surface = replacement;
            }
        } else {
            self.tab_surface = try z2d.Surface.init(.image_surface_rgba, self.allocator, self.window_width, tab_height);
        }

        // The surface is mutated in place below. Do not expose stale region
        // coordinates if a fallible draw operation aborts this raster pass.
        self.invalidateInterestRegion();

        var tab_context = z2d.Context.init(self.io, self.allocator, &self.tab_surface.?);
        defer tab_context.deinit();

        tab_context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 } } } });
        try tab_context.moveTo(0, 0);
        try tab_context.lineTo(@floatFromInt(self.window_width), 0);
        try tab_context.lineTo(@floatFromInt(self.window_width), @floatFromInt(tab_height));
        try tab_context.lineTo(0, @floatFromInt(tab_height));
        try tab_context.closePath();
        try tab_context.fill();

        // Prefer the composited draw list when available so blend-mode effects
        // (like dst_in clipping) render correctly.
        const zoom = self.activeZoom();
        const base_list = self.active_tab_display_list orelse &.{};
        const draw_list = if (self.tab_draw_list.items.len > 0) self.tab_draw_list.items else base_list;
        for (draw_list) |item| {
            try self.drawDisplayItemZ2dContext(&tab_context, item, region.start_px, zoom);
        }

        self.tab_interest_region = region;
        self.tab_interest_region_valid = true;
    }

    fn compositeRasterAndDraw(self: *Browser) !void {
        self.lock.lock();
        defer self.lock.unlock();

        // Check if any phase is needed
        if (!self.needs_composite and !self.needs_raster and !self.needs_draw) return;

        const profiling = self.profiling_enabled;
        const start_ns = if (profiling) std.Io.Clock.awake.now(self.io).nanoseconds else 0;
        var composite_ns: u64 = 0;
        var raster_ns: u64 = 0;
        var draw_ns: u64 = 0;

        const trace_raster = self.measure.begin("composite_raster_draw");
        defer if (trace_raster) self.measure.end("composite_raster_draw");

        // Log which phases will run for animation debugging
        std.log.debug("compositeRasterAndDraw: composite={} raster={} draw={}", .{
            self.needs_composite,
            self.needs_raster,
            self.needs_draw,
        });

        // Composite phase: rebuild composited layers from display list
        if (self.needs_composite) {
            const phase_start = if (profiling) std.Io.Clock.awake.now(self.io).nanoseconds else 0;
            _ = try self.composite();
            try self.paintDrawList();
            self.needs_composite = false;
            // Compositing implies we need to raster the new layers
            self.needs_raster = true;
            if (profiling) {
                composite_ns = @intCast(std.Io.Clock.awake.now(self.io).nanoseconds - phase_start);
            }
        }

        // Raster phase: render layers to surfaces
        if (self.needs_raster) {
            const phase_start = if (profiling) std.Io.Clock.awake.now(self.io).nanoseconds else 0;
            try self.rasterChrome();
            try self.rasterTabSurfaces();
            self.needs_raster = false;
            // Rastering implies we need to draw
            self.needs_draw = true;
            if (profiling) {
                raster_ns = @intCast(std.Io.Clock.awake.now(self.io).nanoseconds - phase_start);
            }
        }

        // Draw phase: composite surfaces to screen
        if (self.needs_draw) {
            const phase_start = if (profiling) std.Io.Clock.awake.now(self.io).nanoseconds else 0;
            try self.draw();
            if (self.canvas) |canvas| canvas.present();
            self.needs_draw = false;
            if (profiling) {
                draw_ns = @intCast(std.Io.Clock.awake.now(self.io).nanoseconds - phase_start);
            }
        }

        if (profiling) {
            const total_ns: u64 = @intCast(std.Io.Clock.awake.now(self.io).nanoseconds - start_ns);
            std.log.info(
                "profile: composite total={}ms comp={}ms raster={}ms draw={}ms",
                .{
                    @divTrunc(total_ns, 1_000_000),
                    @divTrunc(composite_ns, 1_000_000),
                    @divTrunc(raster_ns, 1_000_000),
                    @divTrunc(draw_ns, 1_000_000),
                },
            );
        }
    }

    pub fn setNeedsCompositeRasterDraw(self: *Browser) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.needs_composite = true;
        self.needs_raster = true;
        self.needs_draw = true;
    }

    pub fn setNeedsRasterDraw(self: *Browser) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.needs_raster = true;
        self.needs_draw = true;
    }

    pub fn setNeedsAnimationFrame(self: *Browser, tab: *Tab) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.activeTab()) |active| {
            if (active == tab) {
                self.needs_animation_frame = true;
            }
        }
    }

    pub fn commit(self: *Browser, tab: *Tab, data: CommitData) void {
        self.lock.lock();

        if (self.activeTab() != tab) {
            if (data.display_list) |list| {
                DisplayItem.freeList(self.allocator, list);
            }
            self.lock.unlock();
            return;
        }

        const previous_scroll = self.active_tab_scroll;
        const previous_height = self.active_tab_height;
        const previous_zoom = self.active_tab_zoom;
        var has_display_list_change = false;
        if (data.display_list) |list| {
            var incoming_list = list;
            // Clone to avoid any accidental aliasing with the tab thread's list.
            const cloned_list = self.cloneDisplayItemList(list) catch |err| blk: {
                std.log.warn("Failed to clone display list for commit: {}", .{err});
                break :blk null;
            };
            if (cloned_list) |cloned| {
                DisplayItem.freeList(self.allocator, list);
                incoming_list = cloned;
            }

            // Draw lists and composited layers contain pointers into the old
            // committed list, so retire them before replacing that owner.
            self.retireActiveRenderStateLocked();
            self.active_tab_display_list = incoming_list;
            // Set parent pointers for tree traversal
            DisplayItem.setParentPointers(incoming_list, null);
            has_display_list_change = true;
        }
        if (data.scroll) |scroll| {
            self.active_tab_scroll = scroll;
        }
        self.active_tab_height = data.height;
        self.active_tab_zoom = data.zoom;
        self.active_tab_prefers_dark = data.prefers_dark;

        if (data.url) |url| {
            self.updateCommittedActiveTabUrlLocked(
                url,
                navigationSecurity(url, data.certificate_error),
            );
        } else {
            self.clearActiveTabUrlLocked();
        }

        self.animation_timer_active = false;
        const should_schedule_animation = self.needs_animation_frame;

        // Determine which phases need to run based on what changed
        if (has_display_list_change) {
            // Full display list change requires recomposite/raster/draw
            self.needs_composite = true;
            self.needs_raster = true;
            self.needs_draw = true;
        } else if (data.composited_updates.len > 0) {
            // The bounded tab surface caches the fully assembled page region,
            // so compositor-only changes must be copied into that cache again.
            for (data.composited_updates) |update| {
                self.applyCompositedUpdate(update);
            }
            self.needs_raster = true;
            self.needs_draw = true;
        }

        const geometry_changed = previous_height != self.active_tab_height or
            previous_zoom != self.active_tab_zoom;
        if (geometry_changed) {
            self.invalidateInterestRegion();
            self.needs_raster = true;
            self.needs_draw = true;
        } else if (previous_scroll != self.active_tab_scroll) {
            if (!self.interestRegionContainsScroll(self.active_tab_scroll)) {
                self.needs_raster = true;
            }
            self.needs_draw = true;
        }

        self.lock.unlock();
        if (should_schedule_animation) {
            self.scheduleAnimationFrame();
        }
    }

    /// Apply a composited update to the matching layer
    fn applyCompositedUpdate(self: *Browser, update: Tab.CompositedUpdate) void {
        // Keep the committed source tree current even when the effect is below
        // a transform; a later recomposite must see the animated value.
        if (self.active_tab_display_list) |display_list| {
            _ = DisplayItem.applyCompositedOpacity(display_list, update.node, update.opacity);
        }

        var needs_layer_raster = false;
        for (self.composited_layers.items) |*layer| {
            if (layer.applyCompositedOpacity(update.node, update.opacity)) needs_layer_raster = true;
        }
        if (needs_layer_raster) self.needs_raster = true;
    }

    /// Publish an optimistic address-bar URL by copying it while the caller
    /// still owns the Url. The public writer synchronizes with commit, chrome
    /// paint, and bookmark toggles.
    pub fn setActiveTabUrl(self: *Browser, url: *const Url) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.updateDisplayedActiveTabUrlLocked(url);
    }

    fn updateDisplayedActiveTabUrlLocked(self: *Browser, url: *const Url) void {
        const copy = url.*.toOwnedString(self.allocator) catch |err| {
            std.log.warn("Failed to format URL for chrome: {}", .{err});
            return;
        };

        if (self.active_tab_url) |cached| {
            if (std.mem.eql(u8, cached, copy)) {
                self.allocator.free(copy);
                return;
            }
            self.allocator.free(cached);
        }
        self.active_tab_url = copy;
    }

    /// Commit replaces both independently owned snapshots atomically with
    /// respect to Browser.lock. Bookmarks consult only the committed copy.
    fn updateCommittedActiveTabUrlLocked(
        self: *Browser,
        url: *const Url,
        security: NavigationSecurity,
    ) void {
        const committed_copy = url.*.toOwnedString(self.allocator) catch |err| {
            std.log.warn("Failed to format committed URL for chrome: {}", .{err});
            return;
        };
        const displayed_copy = self.allocator.dupe(u8, committed_copy) catch |err| {
            std.log.warn("Failed to copy committed URL for chrome: {}", .{err});
            self.allocator.free(committed_copy);
            return;
        };

        if (self.active_tab_url) |old| self.allocator.free(old);
        if (self.active_tab_committed_url) |old| self.allocator.free(old);
        self.active_tab_url = displayed_copy;
        self.active_tab_committed_url = committed_copy;
        self.active_tab_committed_security = security;
    }

    /// Restore chrome after an optimistic load could not be scheduled.
    pub fn restoreDisplayedUrlToCommitted(self: *Browser) void {
        self.lock.lock();
        defer self.lock.unlock();

        const replacement = if (self.active_tab_committed_url) |committed|
            self.allocator.dupe(u8, committed) catch |err| blk: {
                std.log.warn("Failed to restore committed URL in chrome: {}", .{err});
                break :blk null;
            }
        else
            null;
        if (self.active_tab_url) |old| self.allocator.free(old);
        self.active_tab_url = replacement;
    }

    fn clearActiveTabUrlLocked(self: *Browser) void {
        if (self.active_tab_url) |old| {
            self.allocator.free(old);
        }
        self.active_tab_url = null;
        if (self.active_tab_committed_url) |old| {
            self.allocator.free(old);
        }
        self.active_tab_committed_url = null;
        self.active_tab_committed_security = .none;
    }

    /// Copy the opaque tab cache into the content viewport. z2d does not expose
    /// Skia's clipRect API; slicing both pixel rows here is the equivalent hard
    /// clip and avoids asking its surface compositor to consume a source taller
    /// than the destination.
    fn copyTabInterestToRoot(self: *Browser, tab_surface: *const z2d.Surface, destination_y: i32) !void {
        const destination = switch (self.root_surface) {
            .image_surface_rgba => |*surface| surface,
            else => return error.UnsupportedRootSurface,
        };
        const source = switch (tab_surface.*) {
            .image_surface_rgba => |*surface| surface,
            else => return error.UnsupportedTabSurface,
        };

        const copy_width_i32 = @min(destination.width, source.width);
        if (copy_width_i32 <= 0) return;

        const destination_top = @max(@max(destination_y, self.chrome.bottom), 0);
        const destination_bottom = @min(
            destination.height,
            destination_y +| source.height,
        );
        if (destination_bottom <= destination_top) return;

        const source_top = destination_top - destination_y;
        const copy_width: usize = @intCast(copy_width_i32);
        const destination_width: usize = @intCast(destination.width);
        const source_width: usize = @intCast(source.width);
        var row: i32 = 0;
        while (row < destination_bottom - destination_top) : (row += 1) {
            const destination_offset = @as(usize, @intCast(destination_top + row)) * destination_width;
            const source_offset = @as(usize, @intCast(source_top + row)) * source_width;
            @memcpy(
                destination.buf[destination_offset..][0..copy_width],
                source.buf[source_offset..][0..copy_width],
            );
        }
    }

    // Draw the browser content (composite from pre-rastered surfaces)
    pub fn draw(self: *Browser) !void {
        // Skip drawing if window dimensions are invalid
        if (self.window_width <= 0 or self.window_height <= 0) {
            return;
        }

        // Recreate the context to avoid corruption issues
        self.context.deinit();
        self.context = z2d.Context.init(self.io, self.allocator, &self.root_surface);

        // Clear root surface to white before drawing.
        self.context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 } } } });
        try self.context.moveTo(0, 0);
        try self.context.lineTo(@floatFromInt(self.window_width), 0);
        try self.context.lineTo(@floatFromInt(self.window_width), @floatFromInt(self.window_height));
        try self.context.lineTo(0, @floatFromInt(self.window_height));
        try self.context.closePath();
        try self.context.fill();
        self.context.resetPath();

        // Move the already-rastered interest region into the clipped page
        // viewport. Chrome is composited separately afterward.
        if (self.active_tab_display_list != null and self.tab_interest_region_valid) {
            if (self.tab_surface) |*tab_surface| {
                const scroll_px = scroll_model.scaleCssPx(self.active_tab_scroll, self.activeZoom());
                const destination_y_i64 = @as(i64, self.chrome.bottom) +
                    @as(i64, self.tab_interest_region.start_px) -
                    @as(i64, scroll_px);
                const destination_y: i32 = @intCast(std.math.clamp(
                    destination_y_i64,
                    @as(i64, std.math.minInt(i32)),
                    @as(i64, std.math.maxInt(i32)),
                ));
                try self.copyTabInterestToRoot(tab_surface, destination_y);
            }
        }

        z2d.Surface.composite(
            &self.root_surface,
            &self.chrome_surface,
            .src_over,
            0,
            0,
            .{},
        );

        try self.drawScrollbarZ2d();

        // Copy composited root surface to SDL for display
        try self.copyZ2dToSDL();
    }

    // Copy z2d surface to SDL for display (surface handoff)
    // Uses persistent cached texture to avoid per-frame texture churn
    fn copyZ2dToSDL(self: *Browser) !void {
        const canvas = self.canvas orelse return;
        const texture = self.cached_texture orelse return error.NoCachedTexture;

        // Get the pixel data from the z2d surface
        const surface_width = self.root_surface.getWidth();
        const surface_height = self.root_surface.getHeight();

        // Get the underlying pixel buffer from z2d surface
        const pixel_data = switch (self.root_surface) {
            .image_surface_rgba => |*img_surface| img_surface.buf,
            else => return error.UnsupportedSurfaceType,
        };

        // Lock the cached texture to get writable pixel buffer
        var pixel_data_result = try texture.lock(null);

        // Get the pixel pointer and stride
        const pixels: [*]u8 = pixel_data_result.pixels;
        const stride = pixel_data_result.stride;

        // Copy pixels from z2d to SDL texture
        // Both use ABGR8888 format (z2d RGBA has r at lowest address)
        const bytes_per_pixel = 4;
        for (0..@intCast(surface_height)) |y| {
            const src_row_start = y * @as(usize, @intCast(surface_width));
            const dst_row_start = y * stride;

            for (0..@intCast(surface_width)) |x| {
                const src_idx = src_row_start + x;
                const dst_idx = dst_row_start + x * bytes_per_pixel;

                const src_pixel = pixel_data[src_idx];

                // Direct copy - z2d RGBA matches SDL ABGR8888 layout
                pixels[dst_idx + 0] = src_pixel.r;
                pixels[dst_idx + 1] = src_pixel.g;
                pixels[dst_idx + 2] = src_pixel.b;
                pixels[dst_idx + 3] = src_pixel.a;
            }
        }

        // MUST unlock before copying to canvas
        pixel_data_result.release();

        // Copy texture to renderer (texture persists for next frame)
        try canvas.copy(texture, null, null);
    }

    fn drawImageNearest(
        self: *Browser,
        context: *z2d.Context,
        image_item: ImageDisplayItem,
        dest_left: i32,
        dest_top: i32,
        dest_right: i32,
        dest_bottom: i32,
        surface_width: i32,
        surface_height: i32,
    ) !void {
        _ = self;
        const dest_width = dest_right - dest_left;
        const dest_height = dest_bottom - dest_top;
        if (dest_width <= 0 or dest_height <= 0) return;
        if (image_item.source_width <= 0 or image_item.source_height <= 0) return;

        var start_x = dest_left;
        if (start_x < 0) start_x = 0;
        var end_x = dest_right;
        if (end_x > surface_width) end_x = surface_width;

        var start_y = dest_top;
        if (start_y < 0) start_y = 0;
        var end_y = dest_bottom;
        if (end_y > surface_height) end_y = surface_height;

        if (end_x <= start_x or end_y <= start_y) return;

        const src_w = image_item.source_width;
        const src_h = image_item.source_height;
        const pixels = image_item.pixels;

        switch (context.surface.*) {
            .image_surface_rgba => |*img_surface| {
                const dest_pixels = img_surface.buf;
                const opacity = std.math.clamp(image_item.opacity, 0.0, 1.0);

                var y = start_y;
                while (y < end_y) : (y += 1) {
                    const src_y = @divTrunc((y - dest_top) * src_h, dest_height);
                    if (src_y < 0 or src_y >= src_h) continue;

                    const row_base = @as(usize, @intCast(y)) * @as(usize, @intCast(surface_width));

                    var x = start_x;
                    while (x < end_x) : (x += 1) {
                        const src_x = @divTrunc((x - dest_left) * src_w, dest_width);
                        if (src_x < 0 or src_x >= src_w) continue;

                        const src_idx = (@as(usize, @intCast(src_y)) * @as(usize, @intCast(src_w)) + @as(usize, @intCast(src_x))) * 4;
                        const src_a = pixels[src_idx + 3];
                        if (src_a == 0) continue;

                        const alpha_f = @as(f64, @floatFromInt(src_a)) * opacity;
                        const alpha = std.math.clamp(@as(i32, @intFromFloat(alpha_f + 0.5)), 0, 255);
                        if (alpha == 0) continue;

                        const dst_idx = row_base + @as(usize, @intCast(x));
                        const dst = dest_pixels[dst_idx];
                        const alpha_u32 = @as(u32, @intCast(alpha));
                        const inv_alpha = 255 - alpha_u32;

                        if (alpha == 255) {
                            dest_pixels[dst_idx] = .{
                                .r = pixels[src_idx + 0],
                                .g = pixels[src_idx + 1],
                                .b = pixels[src_idx + 2],
                                .a = 255,
                            };
                        } else {
                            dest_pixels[dst_idx] = .{
                                .r = @intCast((@as(u32, pixels[src_idx + 0]) * alpha_u32 + @as(u32, dst.r) * inv_alpha) / 255),
                                .g = @intCast((@as(u32, pixels[src_idx + 1]) * alpha_u32 + @as(u32, dst.g) * inv_alpha) / 255),
                                .b = @intCast((@as(u32, pixels[src_idx + 2]) * alpha_u32 + @as(u32, dst.b) * inv_alpha) / 255),
                                .a = @intCast((alpha_u32 + @as(u32, dst.a) * inv_alpha) / 255),
                            };
                        }
                    }
                }
                return;
            },
            else => {},
        }

        var y = start_y;
        while (y < end_y) : (y += 1) {
            const src_y = @divTrunc((y - dest_top) * src_h, dest_height);
            if (src_y < 0 or src_y >= src_h) continue;

            var x = start_x;
            while (x < end_x) : (x += 1) {
                const src_x = @divTrunc((x - dest_left) * src_w, dest_width);
                if (src_x < 0 or src_x >= src_w) continue;

                const src_idx = (@as(usize, @intCast(src_y)) * @as(usize, @intCast(src_w)) + @as(usize, @intCast(src_x))) * 4;
                const a = pixels[src_idx + 3];
                if (a == 0) continue;

                const alpha_f = @as(f64, @floatFromInt(a)) * image_item.opacity;
                const alpha = std.math.clamp(@as(i32, @intFromFloat(alpha_f + 0.5)), 0, 255);
                if (alpha == 0) continue;

                context.resetPath();
                context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{
                    .r = pixels[src_idx + 0],
                    .g = pixels[src_idx + 1],
                    .b = pixels[src_idx + 2],
                    .a = @intCast(alpha),
                } } } });
                context.moveTo(@floatFromInt(x), @floatFromInt(y)) catch continue;
                context.lineTo(@floatFromInt(x + 1), @floatFromInt(y)) catch continue;
                context.lineTo(@floatFromInt(x + 1), @floatFromInt(y + 1)) catch continue;
                context.lineTo(@floatFromInt(x), @floatFromInt(y + 1)) catch continue;
                context.closePath() catch continue;
                context.fill() catch continue;
            }
        }
    }

    // Draw a display item using a specific z2d context
    fn compositePremultipliedSurface(
        self: *Browser,
        context: *z2d.Context,
        surface: *z2d.Surface,
        destination_x: i32,
        destination_y: i32,
        opacity_value: f64,
        operator: compositor.Operator,
    ) !void {
        _ = self;
        const source = switch (surface.*) {
            .image_surface_rgba => |*image_surface| image_surface,
            else => return error.UnsupportedSurfaceType,
        };
        const destination = switch (context.surface.*) {
            .image_surface_rgba => |*image_surface| image_surface,
            else => return error.UnsupportedSurfaceType,
        };
        const opacity = std.math.clamp(opacity_value, 0.0, 1.0);
        if (opacity <= 0.0) return;

        const source_width: usize = @intCast(source.width);
        const source_height: usize = @intCast(source.height);
        const destination_width: usize = @intCast(destination.width);
        const destination_height: i32 = destination.height;
        for (0..source_height) |row| {
            const y = destination_y + @as(i32, @intCast(row));
            if (y < 0 or y >= destination_height) continue;
            for (0..source_width) |column| {
                const x = destination_x + @as(i32, @intCast(column));
                if (x < 0 or x >= destination.width) continue;

                var pixel = source.buf[row * source_width + column];
                if (opacity < 1.0) {
                    pixel.r = @intFromFloat(@round(@as(f64, @floatFromInt(pixel.r)) * opacity));
                    pixel.g = @intFromFloat(@round(@as(f64, @floatFromInt(pixel.g)) * opacity));
                    pixel.b = @intFromFloat(@round(@as(f64, @floatFromInt(pixel.b)) * opacity));
                    pixel.a = @intFromFloat(@round(@as(f64, @floatFromInt(pixel.a)) * opacity));
                }
                const destination_index = @as(usize, @intCast(y)) * destination_width + @as(usize, @intCast(x));
                destination.buf[destination_index] = compositor.runPixelT(
                    z2d.pixel.RGBA,
                    destination.buf[destination_index],
                    z2d.pixel.RGBA,
                    pixel,
                    operator,
                );
            }
        }
    }

    /// Render one element subtree to a transparent surface, blur its
    /// premultiplied pixels, then composite that result as a single image.
    fn drawBlurredChildren(
        self: *Browser,
        context: *z2d.Context,
        children: []DisplayItem,
        radius: f64,
        opacity: f64,
        blend_mode: ?[]const u8,
        destination_x_offset: i32,
        destination_y_offset: i32,
        zoom: f32,
    ) anyerror!void {
        const content_bounds = self.displayItemsBounds(children) orelse return;
        const sigma = radius * @as(f64, zoom);
        const outset: i32 = @intCast(blurKernelRadius(sigma));
        if (outset == 0) {
            for (children) |child| {
                try self.drawDisplayItemZ2dContextForLayer(
                    context,
                    child,
                    -destination_x_offset,
                    -destination_y_offset,
                    zoom,
                );
            }
            return;
        }

        const blur_bounds = content_bounds.outset(outset);
        const width = blur_bounds.width();
        const height = blur_bounds.height();
        if (width <= 0 or height <= 0) return;

        var surface = try z2d.Surface.init(.image_surface_rgba, self.allocator, width, height);
        defer surface.deinit(self.allocator);
        const pixels = switch (surface) {
            .image_surface_rgba => |*image_surface| image_surface.buf,
            else => return error.UnsupportedSurfaceType,
        };
        @memset(pixels, .{ .r = 0, .g = 0, .b = 0, .a = 0 });

        var blur_context = z2d.Context.init(self.io, self.allocator, &surface);
        defer blur_context.deinit();
        for (children) |child| {
            try self.drawDisplayItemZ2dContextForLayer(
                &blur_context,
                child,
                blur_bounds.left,
                blur_bounds.top,
                zoom,
            );
        }
        try gaussianBlurPixels(
            self.allocator,
            pixels,
            @intCast(width),
            @intCast(height),
            sigma,
        );

        const operator = if (blend_mode) |mode| self.parseBlendMode(mode) else context.getOperator();
        try self.compositePremultipliedSurface(
            context,
            &surface,
            blur_bounds.left + destination_x_offset,
            blur_bounds.top + destination_y_offset,
            opacity,
            operator,
        );
    }

    /// Apply a display-list mask to every pixel already present in one
    /// isolated layer. Doing this with the low-level compositor gives dst_in
    /// its required unbounded semantics even when the mask path covers only
    /// part of the temporary surface.
    fn applyDisplayMaskForLayer(
        self: *Browser,
        context: *z2d.Context,
        mask: DisplayItem,
        layer_x: i32,
        layer_y: i32,
        zoom: f32,
    ) anyerror!void {
        const width = context.surface.getWidth();
        const height = context.surface.getHeight();
        if (width <= 0 or height <= 0) return;

        var mask_surface = try z2d.Surface.init(.image_surface_rgba, self.allocator, width, height);
        defer mask_surface.deinit(self.allocator);
        const mask_pixels = switch (mask_surface) {
            .image_surface_rgba => |*image_surface| image_surface.buf,
            else => return error.UnsupportedSurfaceType,
        };
        @memset(mask_pixels, .{ .r = 0, .g = 0, .b = 0, .a = 0 });

        if (mask == .rounded_rect) {
            const rounded = mask.rounded_rect;
            const left = self.scalePxWithZoom(rounded.x1, zoom) - layer_x;
            const right = self.scalePxWithZoom(rounded.x2, zoom) - layer_x;
            const top = self.scalePxWithZoom(rounded.y1, zoom) - layer_y;
            const bottom = self.scalePxWithZoom(rounded.y2, zoom) - layer_y;
            const radius = @min(
                self.scalePxFWithZoom(rounded.radius, zoom),
                @min(
                    @as(f64, @floatFromInt(@max(0, right - left))) / 2.0,
                    @as(f64, @floatFromInt(@max(0, bottom - top))) / 2.0,
                ),
            );
            const width_usize: usize = @intCast(width);
            const sample_offsets = [_]f64{ 0.25, 0.75 };
            for (0..@as(usize, @intCast(height))) |row| {
                for (0..width_usize) |column| {
                    var covered: u8 = 0;
                    for (sample_offsets) |sample_y| {
                        for (sample_offsets) |sample_x| {
                            const x = @as(f64, @floatFromInt(column)) + sample_x;
                            const y = @as(f64, @floatFromInt(row)) + sample_y;
                            if (x < @as(f64, @floatFromInt(left)) or x >= @as(f64, @floatFromInt(right)) or
                                y < @as(f64, @floatFromInt(top)) or y >= @as(f64, @floatFromInt(bottom))) continue;
                            const nearest_x = std.math.clamp(
                                x,
                                @as(f64, @floatFromInt(left)) + radius,
                                @as(f64, @floatFromInt(right)) - radius,
                            );
                            const nearest_y = std.math.clamp(
                                y,
                                @as(f64, @floatFromInt(top)) + radius,
                                @as(f64, @floatFromInt(bottom)) - radius,
                            );
                            const dx = x - nearest_x;
                            const dy = y - nearest_y;
                            if (radius <= 0.5 or dx * dx + dy * dy <= radius * radius) covered += 1;
                        }
                    }
                    const alpha: u8 = @intCast((@as(u16, rounded.color.a) * covered + 2) / 4);
                    mask_pixels[row * width_usize + column] = .{ .r = alpha, .g = alpha, .b = alpha, .a = alpha };
                }
            }
        } else {
            var mask_context = z2d.Context.init(self.io, self.allocator, &mask_surface);
            defer mask_context.deinit();
            try self.drawDisplayItemZ2dContextForLayer(&mask_context, mask, layer_x, layer_y, zoom);
        }

        const destination_pixels = switch (context.surface.*) {
            .image_surface_rgba => |*image_surface| image_surface.buf,
            else => return error.UnsupportedSurfaceType,
        };
        for (destination_pixels, mask_pixels) |*destination, source| {
            destination.* = compositor.runPixelT(
                z2d.pixel.RGBA,
                destination.*,
                z2d.pixel.RGBA,
                source,
                .dst_in,
            );
        }
    }

    fn drawDisplayItemZ2dContext(self: *Browser, context: *z2d.Context, item: DisplayItem, scroll_offset: i32, zoom: f32) !void {
        switch (item) {
            .glyph => |glyph_item| {
                const glyph_x = self.scalePxWithZoom(glyph_item.x, zoom);
                const glyph_y = self.scalePxWithZoom(glyph_item.y, zoom) - scroll_offset;
                try drawGlyphBitmap(context, glyph_item, glyph_x, glyph_y);
            },
            .rect => |rect_item| {
                const left = self.scalePxWithZoom(rect_item.x1, zoom);
                const right = self.scalePxWithZoom(rect_item.x2, zoom);
                const top = self.scalePxWithZoom(rect_item.y1, zoom) - scroll_offset;
                const bottom = self.scalePxWithZoom(rect_item.y2, zoom) - scroll_offset;
                const width = right - left;
                const height = bottom - top;

                // Only draw if rect has valid dimensions and is visible
                if (width > 1 and height > 1 and bottom > 0 and top < context.surface.getHeight()) {
                    // Reset path first to ensure clean state
                    context.resetPath();

                    // Set source color for filling
                    context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = rect_item.color.toZ2dRgba() } } });

                    // Create rectangle path
                    try context.moveTo(@floatFromInt(left), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(right), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(right), @floatFromInt(bottom));
                    try context.lineTo(@floatFromInt(left), @floatFromInt(bottom));
                    try context.closePath();

                    // Fill and reset path after
                    try context.fill();
                    context.resetPath();
                }
            },
            .image => |image_item| {
                const left = self.scalePxWithZoom(image_item.x1, zoom);
                const right = self.scalePxWithZoom(image_item.x2, zoom);
                const top = self.scalePxWithZoom(image_item.y1, zoom) - scroll_offset;
                const bottom = self.scalePxWithZoom(image_item.y2, zoom) - scroll_offset;
                const surface_width = context.surface.getWidth();
                const surface_height = context.surface.getHeight();
                try self.drawImageNearest(
                    context,
                    image_item,
                    left,
                    top,
                    right,
                    bottom,
                    surface_width,
                    surface_height,
                );
            },
            .iframe => {
                // Iframe placeholders are expanded during display list composition.
            },
            .rounded_rect => |rounded_item| {
                const left = self.scalePxWithZoom(rounded_item.x1, zoom);
                const right = self.scalePxWithZoom(rounded_item.x2, zoom);
                const top = self.scalePxWithZoom(rounded_item.y1, zoom) - scroll_offset;
                const bottom = self.scalePxWithZoom(rounded_item.y2, zoom) - scroll_offset;
                if (bottom > 0 and top < context.surface.getHeight()) {
                    const width = right - left;
                    const height = bottom - top;
                    if (width > 1 and height > 1) {
                        context.resetPath();
                        // Set source color for filling
                        context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = rounded_item.color.toZ2dRgba() } } });

                        // Clamp radius to not exceed half the width or height
                        const max_radius = @min(@as(f64, @floatFromInt(width)) / 2.0, @as(f64, @floatFromInt(height)) / 2.0);
                        const radius = @min(self.scalePxFWithZoom(rounded_item.radius, zoom), max_radius);

                        const x1 = @as(f64, @floatFromInt(left));
                        const y1 = @as(f64, @floatFromInt(top));
                        const x2 = x1 + @as(f64, @floatFromInt(width));
                        const y2 = y1 + @as(f64, @floatFromInt(height));

                        // Only draw rounded corners if radius is meaningful
                        if (radius > 0.5) {
                            try context.moveTo(x1 + radius, y1);
                            try context.lineTo(x2 - radius, y1);
                            try context.arc(x2 - radius, y1 + radius, radius, -std.math.pi / 2.0, 0);
                            try context.lineTo(x2, y2 - radius);
                            try context.arc(x2 - radius, y2 - radius, radius, 0, std.math.pi / 2.0);
                            try context.lineTo(x1 + radius, y2);
                            try context.arc(x1 + radius, y2 - radius, radius, std.math.pi / 2.0, std.math.pi);
                            try context.lineTo(x1, y1 + radius);
                            try context.arc(x1 + radius, y1 + radius, radius, -std.math.pi, -std.math.pi / 2.0);
                            try context.closePath();
                            try context.fill();
                        } else {
                            // Draw regular rectangle if radius is too small
                            try context.moveTo(x1, y1);
                            try context.lineTo(x2, y1);
                            try context.lineTo(x2, y2);
                            try context.lineTo(x1, y2);
                            try context.closePath();
                            try context.fill();
                        }
                    }
                }
            },
            .line => |line_item| {
                const x1 = self.scalePxWithZoom(line_item.x1, zoom);
                const x2 = self.scalePxWithZoom(line_item.x2, zoom);
                const y1 = self.scalePxWithZoom(line_item.y1, zoom) - scroll_offset;
                const y2 = self.scalePxWithZoom(line_item.y2, zoom) - scroll_offset;

                // Only draw if line has non-zero length
                const dx = x2 - x1;
                const dy = y2 - y1;
                if (dx != 0 or dy != 0) {
                    // Set source color and line width
                    context.resetPath();
                    context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = line_item.color.toZ2dRgba() } } });
                    context.setLineWidth(@floatFromInt(@max(1, self.scalePxWithZoom(line_item.thickness, zoom))));

                    // Draw the line
                    try context.moveTo(@floatFromInt(x1), @floatFromInt(y1));
                    try context.lineTo(@floatFromInt(x2), @floatFromInt(y2));
                    try context.stroke();
                    context.resetPath();
                }
            },
            .outline => |outline_item| {
                const r = outline_item.rect;
                const left = self.scalePxWithZoom(r.left, zoom);
                const right = self.scalePxWithZoom(r.right, zoom);
                const top = self.scalePxWithZoom(r.top, zoom) - scroll_offset;
                const bottom = self.scalePxWithZoom(r.bottom, zoom) - scroll_offset;

                const width = right - left;
                const height = bottom - top;

                // Only draw if outline has valid dimensions
                if (width > 1 and height > 1) {
                    // Set source color and line width (assuming 1 pixel outline)
                    context.resetPath();
                    context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = outline_item.color.toZ2dRgba() } } });
                    context.setLineWidth(@floatFromInt(@max(1, self.scalePxWithZoom(outline_item.thickness, zoom))));

                    // Draw rectangle outline
                    try context.moveTo(@floatFromInt(left), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(right), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(right), @floatFromInt(bottom));
                    try context.lineTo(@floatFromInt(left), @floatFromInt(bottom));
                    try context.closePath();
                    try context.stroke();
                }
            },
            .blend => |blend_item| {
                if (blend_item.blur_radius > 0.0) {
                    try self.drawBlurredChildren(
                        context,
                        blend_item.children,
                        blend_item.blur_radius,
                        blend_item.opacity,
                        blend_item.blend_mode,
                        0,
                        -scroll_offset,
                        zoom,
                    );
                    return;
                }
                // For blend operations, only create a layer if we have opacity < 1 or a blend mode
                const should_save_layer = blend_item.opacity < 1.0 or blend_item.blend_mode != null;
                const is_dst_in = if (blend_item.blend_mode) |mode| std.mem.eql(u8, mode, "dst_in") else false;

                if (should_save_layer and is_dst_in and blend_item.children.len > 0) {
                    const original_operator = context.getOperator();
                    const content_end = blend_item.children.len - 1;
                    for (blend_item.children[0..content_end]) |child_item| {
                        if (blend_item.opacity < 1.0) {
                            var modified_item = child_item;
                            modified_item = self.applyOpacityToDisplayItem(modified_item, blend_item.opacity);
                            try self.drawDisplayItemZ2dContext(context, modified_item, scroll_offset, zoom);
                        } else {
                            try self.drawDisplayItemZ2dContext(context, child_item, scroll_offset, zoom);
                        }
                    }
                    context.setOperator(self.parseBlendMode("dst_in"));
                    var mask_item = blend_item.children[content_end];
                    if (blend_item.opacity < 1.0) {
                        mask_item = self.applyOpacityToDisplayItem(mask_item, blend_item.opacity);
                    }
                    try self.drawDisplayItemZ2dContext(context, mask_item, scroll_offset, zoom);
                    context.setOperator(original_operator);
                } else if (should_save_layer) {
                    // Save current operator for restoration
                    const original_operator = context.getOperator();

                    // Set blend mode if specified
                    if (blend_item.blend_mode) |mode| {
                        const blend_operator = self.parseBlendMode(mode);
                        context.setOperator(blend_operator);
                    }

                    // Draw children with opacity applied to their colors (since z2d doesn't have layered alpha)
                    for (blend_item.children) |child_item| {
                        if (blend_item.opacity < 1.0) {
                            var modified_item = child_item;
                            modified_item = self.applyOpacityToDisplayItem(modified_item, blend_item.opacity);
                            try self.drawDisplayItemZ2dContext(context, modified_item, scroll_offset, zoom);
                        } else {
                            try self.drawDisplayItemZ2dContext(context, child_item, scroll_offset, zoom);
                        }
                    }

                    // Restore original operator
                    context.setOperator(original_operator);
                } else {
                    // No layer needed, just draw children directly
                    for (blend_item.children) |child_item| {
                        try self.drawDisplayItemZ2dContext(context, child_item, scroll_offset, zoom);
                    }
                }
            },
            .draw_composited_layer => |dcl| {
                // Ensure the layer is rasterized
                try dcl.layer.raster(self.allocator, self);

                if (dcl.layer.surface) |*layer_surface| {
                    // Draw the layer surface at its position with opacity.
                    const layer_y_i64 = @as(i64, dcl.layer.bounds.top) - @as(i64, scroll_offset);
                    const layer_x_i64 = @as(i64, dcl.layer.bounds.left);
                    const layer_y: i32 = @intCast(std.math.clamp(layer_y_i64, @as(i64, std.math.minInt(i32)), @as(i64, std.math.maxInt(i32))));
                    const layer_x: i32 = @intCast(std.math.clamp(layer_x_i64, @as(i64, std.math.minInt(i32)), @as(i64, std.math.maxInt(i32))));
                    const operator = if (dcl.layer.blend_mode) |mode|
                        self.parseBlendMode(mode)
                    else
                        .src_over;
                    try self.compositePremultipliedSurface(
                        context,
                        layer_surface,
                        layer_x,
                        layer_y,
                        dcl.layer.opacity,
                        operator,
                    );
                    // Draw debug border if enabled
                    if (self.debug_layer_borders) {
                        const border_y = layer_y;
                        const border_x = dcl.layer.bounds.left;
                        const border_w = dcl.layer.bounds.width();
                        const border_h = dcl.layer.bounds.height();

                        // Use a bright color (magenta) for visibility
                        context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{ .r = 255, .g = 0, .b = 255, .a = 255 } } } });
                        context.resetPath();

                        // Draw top border
                        try context.moveTo(@floatFromInt(border_x), @floatFromInt(border_y));
                        try context.lineTo(@floatFromInt(border_x + border_w), @floatFromInt(border_y));
                        try context.lineTo(@floatFromInt(border_x + border_w), @floatFromInt(border_y + 2));
                        try context.lineTo(@floatFromInt(border_x), @floatFromInt(border_y + 2));
                        try context.closePath();
                        try context.fill();

                        // Draw bottom border
                        try context.moveTo(@floatFromInt(border_x), @floatFromInt(border_y + border_h - 2));
                        try context.lineTo(@floatFromInt(border_x + border_w), @floatFromInt(border_y + border_h - 2));
                        try context.lineTo(@floatFromInt(border_x + border_w), @floatFromInt(border_y + border_h));
                        try context.lineTo(@floatFromInt(border_x), @floatFromInt(border_y + border_h));
                        try context.closePath();
                        try context.fill();

                        // Draw left border
                        try context.moveTo(@floatFromInt(border_x), @floatFromInt(border_y));
                        try context.lineTo(@floatFromInt(border_x + 2), @floatFromInt(border_y));
                        try context.lineTo(@floatFromInt(border_x + 2), @floatFromInt(border_y + border_h));
                        try context.lineTo(@floatFromInt(border_x), @floatFromInt(border_y + border_h));
                        try context.closePath();
                        try context.fill();

                        // Draw right border
                        try context.moveTo(@floatFromInt(border_x + border_w - 2), @floatFromInt(border_y));
                        try context.lineTo(@floatFromInt(border_x + border_w), @floatFromInt(border_y));
                        try context.lineTo(@floatFromInt(border_x + border_w), @floatFromInt(border_y + border_h));
                        try context.lineTo(@floatFromInt(border_x + border_w - 2), @floatFromInt(border_y + border_h));
                        try context.closePath();
                        try context.fill();
                    }
                }
            },
            .transform => |t| {
                // Apply translation by adjusting scroll offset for children
                const new_scroll_offset = scroll_offset - self.scalePxWithZoom(t.translate_y, zoom);
                for (t.children) |child| {
                    // Recursively draw children with adjusted offset
                    // For x translation, we need to handle it differently since scroll is y-only
                    try self.drawDisplayItemZ2dContextWithTransform(
                        context,
                        child,
                        new_scroll_offset,
                        self.scalePxWithZoom(t.translate_x, zoom),
                        zoom,
                    );
                }
            },
        }
    }

    fn drawGlyphBitmap(
        context: *z2d.Context,
        glyph_item: anytype,
        glyph_x: i32,
        glyph_y: i32,
    ) !void {
        const pixels = glyph_item.glyph.pixels orelse return;
        const img_surface = switch (context.surface.*) {
            .image_surface_rgba => |*img| img,
            else => return error.UnsupportedGlyphSurface,
        };

        const surface_width = img_surface.width;
        const surface_height = img_surface.height;
        const w: i32 = glyph_item.glyph.w;
        const h: i32 = glyph_item.glyph.h;

        if (w <= 0 or h <= 0) return;

        const w_usize: usize = @intCast(w);
        const h_usize: usize = @intCast(h);
        const pixel_count = std.math.mul(usize, w_usize, h_usize) catch
            return error.InvalidGlyphBitmap;
        const byte_count = std.math.mul(usize, pixel_count, 4) catch
            return error.InvalidGlyphBitmap;
        if (pixels.len != byte_count) return error.InvalidGlyphBitmap;

        const start_x_i64 = @max(@as(i64, 0), -@as(i64, glyph_x));
        const start_y_i64 = @max(@as(i64, 0), -@as(i64, glyph_y));
        const end_x_i64 = @min(@as(i64, w), @as(i64, surface_width) - glyph_x);
        const end_y_i64 = @min(@as(i64, h), @as(i64, surface_height) - glyph_y);
        if (end_x_i64 <= start_x_i64 or end_y_i64 <= start_y_i64) return;

        const start_x: i32 = @intCast(start_x_i64);
        const start_y: i32 = @intCast(start_y_i64);
        const end_x: i32 = @intCast(end_x_i64);
        const end_y: i32 = @intCast(end_y_i64);

        const buf = img_surface.buf;
        const surface_w_usize: usize = @intCast(surface_width);

        var y: i32 = start_y;
        while (y < end_y) : (y += 1) {
            const dest_y = glyph_y + y;
            const row_start = @as(usize, @intCast(dest_y)) * surface_w_usize;
            const src_row_start = @as(usize, @intCast(y)) * @as(usize, @intCast(w));

            var x: i32 = start_x;
            while (x < end_x) : (x += 1) {
                const dest_x = glyph_x + x;
                const dst_idx = row_start + @as(usize, @intCast(dest_x));
                const src_idx = (src_row_start + @as(usize, @intCast(x))) * 4;
                const source = glyphSourcePixel(
                    glyph_item.glyph.pixel_mode,
                    pixels[src_idx..][0..4],
                    glyph_item.color,
                ) orelse continue;
                buf[dst_idx] = compositor.runPixelT(
                    z2d.pixel.RGBA,
                    buf[dst_idx],
                    z2d.pixel.RGBA,
                    source,
                    .src_over,
                );
            }
        }
    }

    // Draw a display item with both scroll offset and x translation
    fn drawDisplayItemZ2dContextWithTransform(self: *Browser, context: *z2d.Context, item: DisplayItem, scroll_offset: i32, x_offset: i32, zoom: f32) !void {
        switch (item) {
            .glyph => |glyph_item| {
                const glyph_x = self.scalePxWithZoom(glyph_item.x, zoom) + x_offset;
                const glyph_y = self.scalePxWithZoom(glyph_item.y, zoom) - scroll_offset;
                try drawGlyphBitmap(context, glyph_item, glyph_x, glyph_y);
            },
            .rect => |rect_item| {
                const top = self.scalePxWithZoom(rect_item.y1, zoom) - scroll_offset;
                const bottom = self.scalePxWithZoom(rect_item.y2, zoom) - scroll_offset;
                const left = self.scalePxWithZoom(rect_item.x1, zoom) + x_offset;
                const right = self.scalePxWithZoom(rect_item.x2, zoom) + x_offset;
                const width = right - left;
                const height = bottom - top;

                if (width > 1 and height > 1 and bottom > 0 and top < context.surface.getHeight()) {
                    context.resetPath();
                    context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{
                        .r = rect_item.color.r,
                        .g = rect_item.color.g,
                        .b = rect_item.color.b,
                        .a = rect_item.color.a,
                    } } } });
                    try context.moveTo(@floatFromInt(left), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(right), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(right), @floatFromInt(bottom));
                    try context.lineTo(@floatFromInt(left), @floatFromInt(bottom));
                    try context.closePath();
                    try context.fill();
                }
            },
            .image => |image_item| {
                const top = self.scalePxWithZoom(image_item.y1, zoom) - scroll_offset;
                const bottom = self.scalePxWithZoom(image_item.y2, zoom) - scroll_offset;
                const left = self.scalePxWithZoom(image_item.x1, zoom) + x_offset;
                const right = self.scalePxWithZoom(image_item.x2, zoom) + x_offset;
                const surface_width = context.surface.getWidth();
                const surface_height = context.surface.getHeight();
                try self.drawImageNearest(
                    context,
                    image_item,
                    left,
                    top,
                    right,
                    bottom,
                    surface_width,
                    surface_height,
                );
            },
            .iframe => {
                // Iframe placeholders are expanded during display list composition.
            },
            .rounded_rect => |rr| {
                const top = self.scalePxWithZoom(rr.y1, zoom) - scroll_offset;
                const bottom = self.scalePxWithZoom(rr.y2, zoom) - scroll_offset;
                const left = self.scalePxWithZoom(rr.x1, zoom) + x_offset;
                const right = self.scalePxWithZoom(rr.x2, zoom) + x_offset;
                const width = right - left;
                const height = bottom - top;
                if (width > 1 and height > 1 and bottom > 0 and top < context.surface.getHeight()) {
                    context.resetPath();
                    context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = rr.color.toZ2dRgba() } } });
                    const max_radius = @min(
                        @as(f64, @floatFromInt(width)) / 2.0,
                        @as(f64, @floatFromInt(height)) / 2.0,
                    );
                    const radius = @min(self.scalePxFWithZoom(rr.radius, zoom), max_radius);
                    const x1: f64 = @floatFromInt(left);
                    const y1: f64 = @floatFromInt(top);
                    const x2: f64 = @floatFromInt(right);
                    const y2: f64 = @floatFromInt(bottom);
                    if (radius > 0.5) {
                        try context.moveTo(x1 + radius, y1);
                        try context.lineTo(x2 - radius, y1);
                        try context.arc(x2 - radius, y1 + radius, radius, -std.math.pi / 2.0, 0);
                        try context.lineTo(x2, y2 - radius);
                        try context.arc(x2 - radius, y2 - radius, radius, 0, std.math.pi / 2.0);
                        try context.lineTo(x1 + radius, y2);
                        try context.arc(x1 + radius, y2 - radius, radius, std.math.pi / 2.0, std.math.pi);
                        try context.lineTo(x1, y1 + radius);
                        try context.arc(x1 + radius, y1 + radius, radius, -std.math.pi, -std.math.pi / 2.0);
                    } else {
                        try context.moveTo(x1, y1);
                        try context.lineTo(x2, y1);
                        try context.lineTo(x2, y2);
                        try context.lineTo(x1, y2);
                    }
                    try context.closePath();
                    try context.fill();
                    context.resetPath();
                }
            },
            .line => |l| {
                const y1 = self.scalePxWithZoom(l.y1, zoom) - scroll_offset;
                const y2 = self.scalePxWithZoom(l.y2, zoom) - scroll_offset;
                const x1 = self.scalePxWithZoom(l.x1, zoom) + x_offset;
                const x2 = self.scalePxWithZoom(l.x2, zoom) + x_offset;
                context.resetPath();
                context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{
                    .r = l.color.r,
                    .g = l.color.g,
                    .b = l.color.b,
                    .a = l.color.a,
                } } } });
                context.setLineWidth(@floatFromInt(@max(1, self.scalePxWithZoom(l.thickness, zoom))));
                try context.moveTo(@floatFromInt(x1), @floatFromInt(y1));
                try context.lineTo(@floatFromInt(x2), @floatFromInt(y2));
                try context.stroke();
            },
            .outline => |o| {
                const top = self.scalePxWithZoom(o.rect.top, zoom) - scroll_offset;
                const bottom = self.scalePxWithZoom(o.rect.bottom, zoom) - scroll_offset;
                const left = self.scalePxWithZoom(o.rect.left, zoom) + x_offset;
                const right = self.scalePxWithZoom(o.rect.right, zoom) + x_offset;
                context.resetPath();
                context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{
                    .r = o.color.r,
                    .g = o.color.g,
                    .b = o.color.b,
                    .a = o.color.a,
                } } } });
                context.setLineWidth(@floatFromInt(@max(1, self.scalePxWithZoom(o.thickness, zoom))));
                try context.moveTo(@floatFromInt(left), @floatFromInt(top));
                try context.lineTo(@floatFromInt(right), @floatFromInt(top));
                try context.lineTo(@floatFromInt(right), @floatFromInt(bottom));
                try context.lineTo(@floatFromInt(left), @floatFromInt(bottom));
                try context.closePath();
                try context.stroke();
            },
            .blend => |blend_item| {
                if (blend_item.blur_radius > 0.0) {
                    try self.drawBlurredChildren(
                        context,
                        blend_item.children,
                        blend_item.blur_radius,
                        blend_item.opacity,
                        blend_item.blend_mode,
                        x_offset,
                        -scroll_offset,
                        zoom,
                    );
                    return;
                }
                // For blends, apply opacity and recurse into children with the transform applied
                const should_apply_opacity = blend_item.opacity < 1.0 or blend_item.blend_mode != null;
                const is_dst_in = if (blend_item.blend_mode) |mode| std.mem.eql(u8, mode, "dst_in") else false;

                if (should_apply_opacity and is_dst_in and blend_item.children.len > 0) {
                    const original_operator = context.getOperator();
                    const content_end = blend_item.children.len - 1;
                    for (blend_item.children[0..content_end]) |child| {
                        if (blend_item.opacity < 1.0) {
                            var modified_item = child;
                            modified_item = self.applyOpacityToDisplayItem(modified_item, blend_item.opacity);
                            try self.drawDisplayItemZ2dContextWithTransform(context, modified_item, scroll_offset, x_offset, zoom);
                        } else {
                            try self.drawDisplayItemZ2dContextWithTransform(context, child, scroll_offset, x_offset, zoom);
                        }
                    }
                    context.setOperator(self.parseBlendMode("dst_in"));
                    var mask_item = blend_item.children[content_end];
                    if (blend_item.opacity < 1.0) {
                        mask_item = self.applyOpacityToDisplayItem(mask_item, blend_item.opacity);
                    }
                    try self.drawDisplayItemZ2dContextWithTransform(context, mask_item, scroll_offset, x_offset, zoom);
                    context.setOperator(original_operator);
                } else if (should_apply_opacity) {
                    const original_operator = context.getOperator();
                    if (blend_item.blend_mode) |mode| {
                        context.setOperator(self.parseBlendMode(mode));
                    }

                    for (blend_item.children) |child| {
                        if (blend_item.opacity < 1.0) {
                            var modified_item = child;
                            modified_item = self.applyOpacityToDisplayItem(modified_item, blend_item.opacity);
                            try self.drawDisplayItemZ2dContextWithTransform(context, modified_item, scroll_offset, x_offset, zoom);
                        } else {
                            try self.drawDisplayItemZ2dContextWithTransform(context, child, scroll_offset, x_offset, zoom);
                        }
                    }

                    context.setOperator(original_operator);
                } else {
                    for (blend_item.children) |child| {
                        try self.drawDisplayItemZ2dContextWithTransform(context, child, scroll_offset, x_offset, zoom);
                    }
                }
            },
            .draw_composited_layer => |dcl| {
                // For composited layers, draw at transformed position
                try dcl.layer.raster(self.allocator, self);
                if (dcl.layer.surface) |*layer_surface| {
                    const layer_y = dcl.layer.bounds.top - scroll_offset;
                    const layer_x = dcl.layer.bounds.left + x_offset;
                    const operator = if (dcl.layer.blend_mode) |mode|
                        self.parseBlendMode(mode)
                    else
                        .src_over;
                    try self.compositePremultipliedSurface(
                        context,
                        layer_surface,
                        layer_x,
                        layer_y,
                        dcl.layer.opacity,
                        operator,
                    );
                }
            },
            .transform => |t| {
                // Nested transform: combine offsets
                for (t.children) |child| {
                    try self.drawDisplayItemZ2dContextWithTransform(
                        context,
                        child,
                        scroll_offset - self.scalePxWithZoom(t.translate_y, zoom),
                        x_offset + self.scalePxWithZoom(t.translate_x, zoom),
                        zoom,
                    );
                }
            },
        }
    }

    /// Draw a display item for a composited layer, mapping from absolute to local coordinates
    /// This function offsets all coordinates by the layer's origin to draw in layer-local space
    fn drawDisplayItemZ2dContextForLayer(self: *Browser, context: *z2d.Context, item: DisplayItem, layer_x: i32, layer_y: i32, zoom: f32) !void {
        switch (item) {
            .glyph => |glyph_item| {
                const glyph_x = self.scalePxWithZoom(glyph_item.x, zoom) - layer_x;
                const glyph_y = self.scalePxWithZoom(glyph_item.y, zoom) - layer_y;
                try drawGlyphBitmap(context, glyph_item, glyph_x, glyph_y);
            },
            .rect => |rect_item| {
                // Map absolute coordinates to layer-local space
                const left = self.scalePxWithZoom(rect_item.x1, zoom) - layer_x;
                const right = self.scalePxWithZoom(rect_item.x2, zoom) - layer_x;
                const top = self.scalePxWithZoom(rect_item.y1, zoom) - layer_y;
                const bottom = self.scalePxWithZoom(rect_item.y2, zoom) - layer_y;
                const width = right - left;
                const height = bottom - top;

                if (width > 1 and height > 1) {
                    context.resetPath();
                    context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = rect_item.color.toZ2dRgba() } } });
                    try context.moveTo(@floatFromInt(left), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(right), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(right), @floatFromInt(bottom));
                    try context.lineTo(@floatFromInt(left), @floatFromInt(bottom));
                    try context.closePath();
                    try context.fill();
                    context.resetPath();
                }
            },
            .image => |image_item| {
                const left = self.scalePxWithZoom(image_item.x1, zoom) - layer_x;
                const right = self.scalePxWithZoom(image_item.x2, zoom) - layer_x;
                const top = self.scalePxWithZoom(image_item.y1, zoom) - layer_y;
                const bottom = self.scalePxWithZoom(image_item.y2, zoom) - layer_y;
                const surface_width = context.surface.getWidth();
                const surface_height = context.surface.getHeight();
                try self.drawImageNearest(
                    context,
                    image_item,
                    left,
                    top,
                    right,
                    bottom,
                    surface_width,
                    surface_height,
                );
            },
            .iframe => {
                // Iframe placeholders are expanded during display list composition.
            },
            .rounded_rect => |rr| {
                const left = self.scalePxWithZoom(rr.x1, zoom) - layer_x;
                const right = self.scalePxWithZoom(rr.x2, zoom) - layer_x;
                const top = self.scalePxWithZoom(rr.y1, zoom) - layer_y;
                const bottom = self.scalePxWithZoom(rr.y2, zoom) - layer_y;
                const width = right - left;
                const height = bottom - top;

                if (width > 1 and height > 1) {
                    context.resetPath();
                    context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = rr.color.toZ2dRgba() } } });
                    const max_radius = @min(
                        @as(f64, @floatFromInt(width)) / 2.0,
                        @as(f64, @floatFromInt(height)) / 2.0,
                    );
                    const radius = @min(self.scalePxFWithZoom(rr.radius, zoom), max_radius);
                    const x1: f64 = @floatFromInt(left);
                    const y1: f64 = @floatFromInt(top);
                    const x2: f64 = @floatFromInt(right);
                    const y2: f64 = @floatFromInt(bottom);
                    if (radius > 0.5) {
                        try context.moveTo(x1 + radius, y1);
                        try context.lineTo(x2 - radius, y1);
                        try context.arc(x2 - radius, y1 + radius, radius, -std.math.pi / 2.0, 0);
                        try context.lineTo(x2, y2 - radius);
                        try context.arc(x2 - radius, y2 - radius, radius, 0, std.math.pi / 2.0);
                        try context.lineTo(x1 + radius, y2);
                        try context.arc(x1 + radius, y2 - radius, radius, std.math.pi / 2.0, std.math.pi);
                        try context.lineTo(x1, y1 + radius);
                        try context.arc(x1 + radius, y1 + radius, radius, -std.math.pi, -std.math.pi / 2.0);
                    } else {
                        try context.moveTo(x1, y1);
                        try context.lineTo(x2, y1);
                        try context.lineTo(x2, y2);
                        try context.lineTo(x1, y2);
                    }
                    try context.closePath();
                    try context.fill();
                    context.resetPath();
                }
            },
            .line => |line_item| {
                const x1 = self.scalePxWithZoom(line_item.x1, zoom) - layer_x;
                const x2 = self.scalePxWithZoom(line_item.x2, zoom) - layer_x;
                const y1 = self.scalePxWithZoom(line_item.y1, zoom) - layer_y;
                const y2 = self.scalePxWithZoom(line_item.y2, zoom) - layer_y;

                context.resetPath();
                context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = line_item.color.toZ2dRgba() } } });
                context.setLineWidth(@floatFromInt(@max(1, self.scalePxWithZoom(line_item.thickness, zoom))));
                try context.moveTo(@floatFromInt(x1), @floatFromInt(y1));
                try context.lineTo(@floatFromInt(x2), @floatFromInt(y2));
                try context.stroke();
                context.resetPath();
            },
            .outline => |outline_item| {
                const left = self.scalePxWithZoom(outline_item.rect.left, zoom) - layer_x;
                const right = self.scalePxWithZoom(outline_item.rect.right, zoom) - layer_x;
                const top = self.scalePxWithZoom(outline_item.rect.top, zoom) - layer_y;
                const bottom = self.scalePxWithZoom(outline_item.rect.bottom, zoom) - layer_y;

                context.resetPath();
                context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = outline_item.color.toZ2dRgba() } } });
                context.setLineWidth(@floatFromInt(@max(1, self.scalePxWithZoom(outline_item.thickness, zoom))));
                try context.moveTo(@floatFromInt(left), @floatFromInt(top));
                try context.lineTo(@floatFromInt(right), @floatFromInt(top));
                try context.lineTo(@floatFromInt(right), @floatFromInt(bottom));
                try context.lineTo(@floatFromInt(left), @floatFromInt(bottom));
                try context.closePath();
                try context.stroke();
                context.resetPath();
            },
            .blend => |blend_item| {
                if (blend_item.blur_radius > 0.0) {
                    try self.drawBlurredChildren(
                        context,
                        blend_item.children,
                        blend_item.blur_radius,
                        blend_item.opacity,
                        blend_item.blend_mode,
                        -layer_x,
                        -layer_y,
                        zoom,
                    );
                    return;
                }
                // Check if this is a dst_in clipping blend
                const is_dst_in_clip = if (blend_item.blend_mode) |mode|
                    std.mem.eql(u8, mode, "dst_in")
                else
                    false;

                if (is_dst_in_clip and blend_item.children.len > 0) {
                    const content_end = blend_item.children.len - 1;
                    for (blend_item.children[0..content_end]) |child| {
                        if (blend_item.opacity < 1.0) {
                            var modified_item = child;
                            modified_item = self.applyOpacityToDisplayItem(modified_item, blend_item.opacity);
                            try self.drawDisplayItemZ2dContextForLayer(context, modified_item, layer_x, layer_y, zoom);
                        } else {
                            try self.drawDisplayItemZ2dContextForLayer(context, child, layer_x, layer_y, zoom);
                        }
                    }
                    var mask_item = blend_item.children[content_end];
                    if (blend_item.opacity < 1.0) {
                        mask_item = self.applyOpacityToDisplayItem(mask_item, blend_item.opacity);
                    }
                    try self.applyDisplayMaskForLayer(context, mask_item, layer_x, layer_y, zoom);
                } else {
                    // Apply opacity and recursively draw children in layer space
                    const should_apply_opacity = blend_item.opacity < 1.0 or blend_item.blend_mode != null;

                    if (should_apply_opacity) {
                        const original_operator = context.getOperator();
                        if (blend_item.blend_mode) |mode| {
                            context.setOperator(self.parseBlendMode(mode));
                        }

                        for (blend_item.children, 0..) |child, i| {
                            _ = i;
                            if (blend_item.opacity < 1.0) {
                                var modified_item = child;
                                modified_item = self.applyOpacityToDisplayItem(modified_item, blend_item.opacity);
                                try self.drawDisplayItemZ2dContextForLayer(context, modified_item, layer_x, layer_y, zoom);
                            } else {
                                try self.drawDisplayItemZ2dContextForLayer(context, child, layer_x, layer_y, zoom);
                            }
                        }

                        context.setOperator(original_operator);
                    } else {
                        for (blend_item.children) |child| {
                            try self.drawDisplayItemZ2dContextForLayer(context, child, layer_x, layer_y, zoom);
                        }
                    }
                }
            },
            .draw_composited_layer => {
                // Nested composited layers shouldn't appear in flattened content
                // They would have been handled by the compositing pass
            },
            .transform => |t| {
                // Apply transform offsets to the layer coordinates
                for (t.children) |child| {
                    try self.drawDisplayItemZ2dContextForLayer(
                        context,
                        child,
                        layer_x - self.scalePxWithZoom(t.translate_x, zoom),
                        layer_y - self.scalePxWithZoom(t.translate_y, zoom),
                        zoom,
                    );
                }
            },
        }
    }

    // Parse CSS blend mode string to z2d compositing operator
    fn parseBlendMode(self: *Browser, blend_mode_str: []const u8) compositor.Operator {
        _ = self;
        if (std.mem.eql(u8, blend_mode_str, "multiply")) {
            return .multiply;
        } else if (std.mem.eql(u8, blend_mode_str, "screen")) {
            return .screen;
        } else if (std.mem.eql(u8, blend_mode_str, "overlay")) {
            return .overlay;
        } else if (std.mem.eql(u8, blend_mode_str, "darken")) {
            return .darken;
        } else if (std.mem.eql(u8, blend_mode_str, "lighten")) {
            return .lighten;
        } else if (std.mem.eql(u8, blend_mode_str, "color-dodge")) {
            return .color_dodge;
        } else if (std.mem.eql(u8, blend_mode_str, "color-burn")) {
            return .color_burn;
        } else if (std.mem.eql(u8, blend_mode_str, "hard-light")) {
            return .hard_light;
        } else if (std.mem.eql(u8, blend_mode_str, "soft-light")) {
            return .soft_light;
        } else if (std.mem.eql(u8, blend_mode_str, "difference")) {
            return .difference;
        } else if (std.mem.eql(u8, blend_mode_str, "exclusion")) {
            return .exclusion;
        } else if (std.mem.eql(u8, blend_mode_str, "dst_in")) {
            return .dst_in;
        } else {
            // Default to src_over for unknown blend modes
            return .src_over;
        }
    }

    // Apply opacity to a display item's colors
    fn applyOpacityToDisplayItem(self: *Browser, item: DisplayItem, opacity: f64) DisplayItem {
        _ = self; // Used for context
        var result = item;

        switch (result) {
            .glyph => |*glyph_item| {
                glyph_item.color.a = @as(u8, @intFromFloat(@round(@as(f64, @floatFromInt(glyph_item.color.a)) * opacity)));
            },
            .rect => |*rect_item| {
                rect_item.color.a = @as(u8, @intFromFloat(@round(@as(f64, @floatFromInt(rect_item.color.a)) * opacity)));
            },
            .image => |*image_item| {
                image_item.opacity *= opacity;
            },
            .iframe => {
                // Iframe placeholders are expanded during display list composition.
            },
            .rounded_rect => |*rounded_item| {
                rounded_item.color.a = @as(u8, @intFromFloat(@round(@as(f64, @floatFromInt(rounded_item.color.a)) * opacity)));
            },
            .line => |*line_item| {
                line_item.color.a = @as(u8, @intFromFloat(@round(@as(f64, @floatFromInt(line_item.color.a)) * opacity)));
            },
            .outline => |*outline_item| {
                outline_item.color.a = @as(u8, @intFromFloat(@round(@as(f64, @floatFromInt(outline_item.color.a)) * opacity)));
            },
            .blend => |*blend_item| {
                // For nested blend operations with blend modes (like dst_in for clipping),
                // do NOT multiply opacity - the mask needs full opacity to work correctly
                if (blend_item.blend_mode == null) {
                    blend_item.opacity *= opacity;
                }
                // Blends with modes (clipping masks) keep their original opacity
            },
            .draw_composited_layer => {
                // Composited layers handle their own opacity
            },
            .transform => {
                // Transform items don't have direct color, opacity applied to children
            },
        }

        return result;
    }

    fn drawScrollbarZ2d(self: *Browser) !void {
        const metrics = scroll_model.calculate(
            self.active_tab_height,
            self.window_height - self.chrome.bottom,
            self.active_tab_scroll,
            self.activeZoom(),
        );
        if (!metrics.visible) return;

        // Draw scrollbar track (background) - start below chrome
        self.context.resetPath();
        self.context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{ .r = 200, .g = 200, .b = 200, .a = 255 } } } }); // Light gray
        const track_x = self.window_width - scrollbar_width;
        const track_y = self.chrome.bottom;
        try self.context.moveTo(@floatFromInt(track_x), @floatFromInt(track_y));
        try self.context.lineTo(@floatFromInt(track_x + scrollbar_width), @floatFromInt(track_y));
        try self.context.lineTo(@floatFromInt(track_x + scrollbar_width), @floatFromInt(track_y + metrics.track_height_px));
        try self.context.lineTo(@floatFromInt(track_x), @floatFromInt(track_y + metrics.track_height_px));
        try self.context.closePath();
        try self.context.fill();

        // Draw scrollbar thumb (movable part) - offset by chrome height
        self.context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{ .r = 0, .g = 102, .b = 204, .a = 255 } } } }); // Blue
        const thumb_x = self.window_width - scrollbar_width;
        const thumb_y = self.chrome.bottom + metrics.thumb_offset_px;
        try self.context.moveTo(@floatFromInt(thumb_x), @floatFromInt(thumb_y));
        try self.context.lineTo(@floatFromInt(thumb_x + scrollbar_width), @floatFromInt(thumb_y));
        try self.context.lineTo(@floatFromInt(thumb_x + scrollbar_width), @floatFromInt(thumb_y + metrics.thumb_height_px));
        try self.context.lineTo(@floatFromInt(thumb_x), @floatFromInt(thumb_y + metrics.thumb_height_px));
        try self.context.closePath();
        try self.context.fill();
        self.context.resetPath();
    }

    pub fn deinit(self: *Browser) void {
        // First stop every producer while all Browser-owned services remain
        // alive. Never hold the browser lock while joining or waiting.
        self.lock.lock();
        self.shutting_down = true;
        self.needs_animation_frame = false;
        self.pending_post_resubmission = null;
        self.lock.unlock();
        for (self.tabs.items) |tab| tab.shutdown();

        // No tab can publish another commit now. Retire browser-side display
        // snapshots before destroying the document/font/image data they borrow.
        self.lock.lock();
        self.retireActiveRenderStateLocked();
        self.lock.unlock();

        for (self.tabs.items) |tab| {
            tab.deinit();
            self.allocator.destroy(tab);
        }
        self.tabs.deinit(self.allocator);

        for (self.pending_new_tabs.items) |*url| url.free(self.allocator);
        self.pending_new_tabs.deinit(self.allocator);

        if (self.owns_session) {
            self.session_state.deinit();
            self.allocator.destroy(self.session_state);
        }

        if (self.active_tab_url) |url| {
            self.allocator.free(url);
        }
        if (self.active_tab_committed_url) |url| {
            self.allocator.free(url);
        }

        self.composited_layers.deinit(self.allocator);
        self.tab_draw_list.deinit(self.allocator);

        self.chrome.deinit();

        for (self.default_style_sheet_rules) |*rule| {
            rule.deinit(self.allocator);
        }
        self.allocator.free(self.default_style_sheet_rules);

        // Retire presentation resources, then SDL_ttf/font state, while SDL is
        // still initialized. Headless screenshot mode owns no presentation
        // resources here.
        if (self.cached_texture) |texture| texture.destroy();
        self.layout_engine.deinit();

        self.context.deinit();
        self.root_surface.deinit(self.allocator);
        self.chrome_surface.deinit(self.allocator);
        if (self.tab_surface) |*tab_surface| {
            tab_surface.deinit(self.allocator);
        }

        if (self.owns_measure) {
            self.measure.finish();
            self.allocator.destroy(self.measure);
        }

        if (self.owns_text_input) sdl2.stopTextInput();
        if (self.canvas) |canvas| canvas.destroy();
        if (self.window) |window| window.destroy();
        if (self.owns_sdl) sdl2.quit();
    }
};

pub const CommitData = struct {
    url: ?*Url,
    certificate_error: bool = false,
    display_list: ?[]DisplayItem,
    scroll: ?i32,
    height: i32,
    zoom: f32,
    prefers_dark: bool,
    composited_updates: []const Tab.CompositedUpdate = &.{},
};

const LoadTaskContext = struct {
    allocator: std.mem.Allocator,
    browser: *Browser,
    tab: *Tab,
    url: ?*Url,
    payload: ?[]const u8,

    fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        tab: *Tab,
        url: *Url,
        payload: ?[]const u8,
    ) !*LoadTaskContext {
        const ctx = try allocator.create(LoadTaskContext);
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .tab = tab,
            .url = url,
            .payload = payload,
        };
        return ctx;
    }

    fn destroy(self: *LoadTaskContext) void {
        self.consumePayload();
        if (self.url) |url_ptr| {
            url_ptr.*.free(self.allocator);
            self.allocator.destroy(url_ptr);
        }
        self.allocator.destroy(self);
    }

    fn consumePayload(self: *LoadTaskContext) void {
        if (self.payload) |payload| {
            self.allocator.free(payload);
            self.payload = null;
        }
    }

    fn run(self: *LoadTaskContext) !void {
        defer self.consumePayload();
        try self.browser.loadInTab(self.tab, self.url.?, self.payload, .push);
        self.url = null;
    }

    fn toOpaque(self: *LoadTaskContext) *anyopaque {
        return @ptrCast(self);
    }

    fn fromOpaque(context: *anyopaque) *LoadTaskContext {
        const raw: *align(1) LoadTaskContext = @ptrCast(context);
        return @alignCast(raw);
    }

    fn runOpaque(context: *anyopaque) anyerror!void {
        try LoadTaskContext.fromOpaque(context).run();
    }

    fn cleanupOpaque(context: *anyopaque) void {
        LoadTaskContext.fromOpaque(context).destroy();
    }
};

const FrameLoadTaskContext = struct {
    allocator: std.mem.Allocator,
    browser: *Browser,
    tab: *Tab,
    document: DocumentHandle,
    url: ?*Url,
    payload: ?[]const u8,

    fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        frame: *Frame,
        url: *Url,
        payload: ?[]const u8,
    ) !*FrameLoadTaskContext {
        const ctx = try allocator.create(FrameLoadTaskContext);
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .tab = frame.tab,
            .document = DocumentHandle.fromFrame(frame),
            .url = url,
            .payload = payload,
        };
        return ctx;
    }

    fn destroy(self: *FrameLoadTaskContext) void {
        self.consumePayload();
        if (self.url) |url_ptr| {
            url_ptr.*.free(self.allocator);
            self.allocator.destroy(url_ptr);
        }
        self.allocator.destroy(self);
    }

    fn consumePayload(self: *FrameLoadTaskContext) void {
        if (self.payload) |payload| {
            self.allocator.free(payload);
            self.payload = null;
        }
    }

    fn run(self: *FrameLoadTaskContext) !void {
        defer self.consumePayload();
        const frame = self.document.resolve(self.tab) orelse return;
        try self.browser.loadInFrame(frame, self.url.?, self.payload);
    }

    fn toOpaque(self: *FrameLoadTaskContext) *anyopaque {
        return @ptrCast(self);
    }

    fn fromOpaque(context: *anyopaque) *FrameLoadTaskContext {
        const raw: *align(1) FrameLoadTaskContext = @ptrCast(context);
        return @alignCast(raw);
    }

    fn runOpaque(context: *anyopaque) anyerror!void {
        try FrameLoadTaskContext.fromOpaque(context).run();
    }

    fn cleanupOpaque(context: *anyopaque) void {
        FrameLoadTaskContext.fromOpaque(context).destroy();
    }
};

const TabClickTaskContext = struct {
    allocator: std.mem.Allocator,
    browser: *Browser,
    tab: *Tab,
    x: i32,
    y: i32,
    button: ClickButton,
    zoom: f32,

    fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        tab: *Tab,
        x: i32,
        y: i32,
        button: ClickButton,
        zoom: f32,
    ) !*TabClickTaskContext {
        const ctx = try allocator.create(TabClickTaskContext);
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .tab = tab,
            .x = x,
            .y = y,
            .button = button,
            .zoom = zoom,
        };
        return ctx;
    }

    fn destroy(self: *TabClickTaskContext) void {
        self.allocator.destroy(self);
    }

    fn run(self: *TabClickTaskContext) !void {
        try self.tab.clickDevice(self.browser, self.x, self.y, self.button, self.zoom);
    }

    fn toOpaque(self: *TabClickTaskContext) *anyopaque {
        return @ptrCast(self);
    }

    fn fromOpaque(context: *anyopaque) *TabClickTaskContext {
        const raw: *align(1) TabClickTaskContext = @ptrCast(context);
        return @alignCast(raw);
    }

    fn runOpaque(context: *anyopaque) anyerror!void {
        try TabClickTaskContext.fromOpaque(context).run();
    }

    fn cleanupOpaque(context: *anyopaque) void {
        TabClickTaskContext.fromOpaque(context).destroy();
    }
};

const TabKeypressTaskContext = struct {
    allocator: std.mem.Allocator,
    browser: *Browser,
    tab: *Tab,
    char: u8,

    fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        tab: *Tab,
        char: u8,
    ) !*TabKeypressTaskContext {
        const ctx = try allocator.create(TabKeypressTaskContext);
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .tab = tab,
            .char = char,
        };
        return ctx;
    }

    fn destroy(self: *TabKeypressTaskContext) void {
        self.allocator.destroy(self);
    }

    fn run(self: *TabKeypressTaskContext) !void {
        try self.tab.keypress(self.browser, self.char);
    }

    fn toOpaque(self: *TabKeypressTaskContext) *anyopaque {
        return @ptrCast(self);
    }

    fn fromOpaque(context: *anyopaque) *TabKeypressTaskContext {
        const raw: *align(1) TabKeypressTaskContext = @ptrCast(context);
        return @alignCast(raw);
    }

    fn runOpaque(context: *anyopaque) anyerror!void {
        try TabKeypressTaskContext.fromOpaque(context).run();
    }

    fn cleanupOpaque(context: *anyopaque) void {
        TabKeypressTaskContext.fromOpaque(context).destroy();
    }
};

const TabHistoryTaskContext = struct {
    const Request = union(enum) {
        direction: HistoryDirection,
        resubmit: struct {
            target: usize,
            history_generation: u64,
        },
    };

    allocator: std.mem.Allocator,
    browser: *Browser,
    tab: *Tab,
    request: Request,

    fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        tab: *Tab,
        request: Request,
    ) !*TabHistoryTaskContext {
        const ctx = try allocator.create(TabHistoryTaskContext);
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .tab = tab,
            .request = request,
        };
        return ctx;
    }

    fn destroy(self: *TabHistoryTaskContext) void {
        self.allocator.destroy(self);
    }

    fn run(self: *TabHistoryTaskContext) !void {
        switch (self.request) {
            .direction => |direction| try self.tab.traverseHistory(self.browser, direction),
            .resubmit => |request| try self.tab.resubmitHistoryEntry(
                self.browser,
                request.target,
                request.history_generation,
            ),
        }
    }

    fn toOpaque(self: *TabHistoryTaskContext) *anyopaque {
        return @ptrCast(self);
    }

    fn fromOpaque(context: *anyopaque) *TabHistoryTaskContext {
        const raw: *align(1) TabHistoryTaskContext = @ptrCast(context);
        return @alignCast(raw);
    }

    fn runOpaque(context: *anyopaque) anyerror!void {
        try TabHistoryTaskContext.fromOpaque(context).run();
    }

    fn cleanupOpaque(context: *anyopaque) void {
        TabHistoryTaskContext.fromOpaque(context).destroy();
    }
};

const TabBackspaceTaskContext = struct {
    allocator: std.mem.Allocator,
    browser: *Browser,
    tab: *Tab,

    fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        tab: *Tab,
    ) !*TabBackspaceTaskContext {
        const ctx = try allocator.create(TabBackspaceTaskContext);
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .tab = tab,
        };
        return ctx;
    }

    fn destroy(self: *TabBackspaceTaskContext) void {
        self.allocator.destroy(self);
    }

    fn run(self: *TabBackspaceTaskContext) !void {
        try self.tab.backspace(self.browser);
    }

    fn toOpaque(self: *TabBackspaceTaskContext) *anyopaque {
        return @ptrCast(self);
    }

    fn fromOpaque(context: *anyopaque) *TabBackspaceTaskContext {
        const raw: *align(1) TabBackspaceTaskContext = @ptrCast(context);
        return @alignCast(raw);
    }

    fn runOpaque(context: *anyopaque) anyerror!void {
        try TabBackspaceTaskContext.fromOpaque(context).run();
    }

    fn cleanupOpaque(context: *anyopaque) void {
        TabBackspaceTaskContext.fromOpaque(context).destroy();
    }
};

const TabScrollTaskContext = struct {
    allocator: std.mem.Allocator,
    browser: *Browser,
    tab: *Tab,
    delta: i32,

    fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        tab: *Tab,
        delta: i32,
    ) !*TabScrollTaskContext {
        const ctx = try allocator.create(TabScrollTaskContext);
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .tab = tab,
            .delta = delta,
        };
        return ctx;
    }

    fn destroy(self: *TabScrollTaskContext) void {
        self.allocator.destroy(self);
    }

    fn run(self: *TabScrollTaskContext) !void {
        self.tab.scrollFocused(self.browser, self.delta);
    }

    fn toOpaque(self: *TabScrollTaskContext) *anyopaque {
        return @ptrCast(self);
    }

    fn fromOpaque(context: *anyopaque) *TabScrollTaskContext {
        const raw: *align(1) TabScrollTaskContext = @ptrCast(context);
        return @alignCast(raw);
    }

    fn runOpaque(context: *anyopaque) anyerror!void {
        try TabScrollTaskContext.fromOpaque(context).run();
    }

    fn cleanupOpaque(context: *anyopaque) void {
        TabScrollTaskContext.fromOpaque(context).destroy();
    }
};

const TabBlurTaskContext = struct {
    allocator: std.mem.Allocator,
    browser: *Browser,
    tab: *Tab,

    fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        tab: *Tab,
    ) !*TabBlurTaskContext {
        const ctx = try allocator.create(TabBlurTaskContext);
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .tab = tab,
        };
        return ctx;
    }

    fn destroy(self: *TabBlurTaskContext) void {
        self.allocator.destroy(self);
    }

    fn run(self: *TabBlurTaskContext) !void {
        if (self.tab.blur()) {
            self.tab.updateAccessibilityFocus(self.browser);
            self.tab.setNeedsRender();
        }
    }

    fn toOpaque(self: *TabBlurTaskContext) *anyopaque {
        return @ptrCast(self);
    }

    fn fromOpaque(context: *anyopaque) *TabBlurTaskContext {
        const raw: *align(1) TabBlurTaskContext = @ptrCast(context);
        return @alignCast(raw);
    }

    fn runOpaque(context: *anyopaque) anyerror!void {
        try TabBlurTaskContext.fromOpaque(context).run();
    }

    fn cleanupOpaque(context: *anyopaque) void {
        TabBlurTaskContext.fromOpaque(context).destroy();
    }
};

const TabResizeTaskContext = struct {
    allocator: std.mem.Allocator,
    browser: *Browser,
    tab: *Tab,
    width: i32,
    height: i32,
    generation: u64,

    fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        tab: *Tab,
        width: i32,
        height: i32,
        generation: u64,
    ) !*TabResizeTaskContext {
        const ctx = try allocator.create(TabResizeTaskContext);
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .tab = tab,
            .width = width,
            .height = height,
            .generation = generation,
        };
        return ctx;
    }

    fn destroy(self: *TabResizeTaskContext) void {
        self.allocator.destroy(self);
    }

    fn run(self: *TabResizeTaskContext) void {
        if (self.tab.isShuttingDown()) return;
        if (self.generation != self.browser.resize_generation.load(.seq_cst)) return;

        self.tab.resizeViewport(self.width, self.height);
        self.browser.setNeedsAnimationFrame(self.tab);
        self.browser.scheduleAnimationFrame();
    }

    fn toOpaque(self: *TabResizeTaskContext) *anyopaque {
        return @ptrCast(self);
    }

    fn fromOpaque(context: *anyopaque) *TabResizeTaskContext {
        const raw: *align(1) TabResizeTaskContext = @ptrCast(context);
        return @alignCast(raw);
    }

    fn runOpaque(context: *anyopaque) anyerror!void {
        TabResizeTaskContext.fromOpaque(context).run();
    }

    fn cleanupOpaque(context: *anyopaque) void {
        TabResizeTaskContext.fromOpaque(context).destroy();
    }
};

const ScriptTaskContext = struct {
    allocator: std.mem.Allocator,
    browser: *Browser,
    tab: *Tab,
    document: DocumentHandle,
    script_label: []const u8,
    script_url: Url,
    script_body: []const u8,

    fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        tab: *Tab,
        document: DocumentHandle,
        script_label: []const u8,
        script_url: Url,
        script_body: []const u8,
    ) !*ScriptTaskContext {
        const ctx = try allocator.create(ScriptTaskContext);
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .tab = tab,
            .document = document,
            .script_label = script_label,
            .script_url = script_url,
            .script_body = script_body,
        };
        return ctx;
    }

    fn destroy(self: *ScriptTaskContext) void {
        self.script_url.free(self.allocator);
        self.allocator.free(self.script_body);
        self.allocator.free(self.script_label);
        self.allocator.destroy(self);
    }

    fn toOpaque(self: *ScriptTaskContext) *anyopaque {
        return @ptrCast(self);
    }

    fn fromOpaque(context: *anyopaque) *ScriptTaskContext {
        const raw: *align(1) ScriptTaskContext = @ptrCast(context);
        return @alignCast(raw);
    }

    fn runOpaque(context: *anyopaque) anyerror!void {
        try ScriptTaskContext.fromOpaque(context).run();
    }

    fn cleanupOpaque(context: *anyopaque) void {
        ScriptTaskContext.fromOpaque(context).destroy();
    }

    fn run(self: *ScriptTaskContext) !void {
        const frame = self.document.resolve(self.tab) orelse return;
        const js_context = frame.js_context orelse return;

        std.log.info("Executing script for window_id={d}", .{self.document.window_id});
        std.log.info("========== Executing script ==========", .{});
        const trace_eval = self.browser.measure.begin("evaljs");
        defer if (trace_eval) self.browser.measure.end("evaljs");
        const result = js_context.evaluate(self.document.window_id, self.script_body) catch |err| {
            std.log.err("Script {s} crashed: {}", .{ self.script_label, err });
            return;
        };

        var result_buf: [4096]u8 = undefined;
        const result_str = js_module.formatValue(result, &result_buf) catch |err| {
            std.log.err("Failed to format script result: {}", .{err});
            return;
        };

        std.log.info("Script result: {s}", .{result_str});
        std.log.info("======================================", .{});

        if (!std.mem.eql(u8, result_str, "undefined")) {
            self.injectResult(result_str) catch |err| {
                std.log.warn("Failed to inject script result: {}", .{err});
            };
        }
    }

    fn injectResult(self: *ScriptTaskContext, result_str: []const u8) anyerror!void {
        const frame = self.document.resolve(self.tab) orelse return;
        if (frame.current_node == null) return;

        const allocator = self.browser.allocator;
        const result_text = try allocator.alloc(u8, result_str.len);
        @memcpy(result_text, result_str);

        var node_list = std.ArrayList(*Node).empty;
        defer node_list.deinit(allocator);

        try parser.treeToList(allocator, &frame.current_node.?, &node_list);

        var body_node: ?*Node = null;
        for (node_list.items) |node_ptr| {
            switch (node_ptr.*) {
                .element => |e| {
                    if (std.mem.eql(u8, e.tag, "body")) {
                        body_node = node_ptr;
                        break;
                    }
                },
                .text => {},
            }
        }

        if (body_node) |body_elem| {
            const text_node = Node{ .text = .{
                .text = result_text,
                .parent = body_elem,
            } };
            try body_elem.appendChild(allocator, text_node);
            try self.tab.dynamic_texts.append(allocator, result_text);
            parser.fixParentPointers(&frame.current_node.?, null);
            try self.tab.render(self.browser);
        } else {
            allocator.free(result_text);
        }
    }
};

const SetTimeoutThreadContext = struct {
    allocator: std.mem.Allocator,
    browser: *Browser,
    tab: *Tab,
    document: DocumentHandle,
    handle: u32,
    delay_ms: u32,

    fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        tab: *Tab,
        document: DocumentHandle,
        handle: u32,
        delay_ms: u32,
    ) !*SetTimeoutThreadContext {
        const ctx = try allocator.create(SetTimeoutThreadContext);
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .tab = tab,
            .document = document,
            .handle = handle,
            .delay_ms = delay_ms,
        };
        return ctx;
    }

    fn destroy(self: *SetTimeoutThreadContext) void {
        self.allocator.destroy(self);
    }
};

fn runSetTimeoutThread(ctx: *SetTimeoutThreadContext) void {
    const tab = ctx.tab;
    defer {
        ctx.destroy();
        tab.releaseAsyncThread();
    }

    _ = ctx.browser.measure.registerThread("SetTimeout thread") catch |err| {
        std.log.warn("Failed to register setTimeout thread: {}", .{err});
    };

    var remaining_ns = @as(u64, ctx.delay_ms) * std.time.ns_per_ms;
    while (remaining_ns > 0) {
        if (tab.isShuttingDown()) return;
        const sleep_ns = @min(remaining_ns, 10 * std.time.ns_per_ms);
        ctx.browser.io.sleep(.fromNanoseconds(@intCast(sleep_ns)), .awake) catch return;
        remaining_ns -= sleep_ns;
    }
    if (tab.isShuttingDown()) return;

    const task_ctx = SetTimeoutTaskContext.create(
        ctx.browser.allocator,
        ctx.browser,
        tab,
        ctx.document,
        ctx.handle,
    ) catch |err| {
        std.log.warn("Failed to allocate setTimeout task: {}", .{err});
        return;
    };
    errdefer task_ctx.destroy();

    const task = Task.init(
        task_ctx.toOpaque(),
        SetTimeoutTaskContext.runOpaque,
        SetTimeoutTaskContext.cleanupOpaque,
    );

    tab.task_runner.schedule(task) catch |err| {
        std.log.warn("Failed to enqueue setTimeout task: {}", .{err});
        task_ctx.destroy();
    };
}

const SetTimeoutTaskContext = struct {
    allocator: std.mem.Allocator,
    browser: *Browser,
    tab: *Tab,
    document: DocumentHandle,
    handle: u32,

    fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        tab: *Tab,
        document: DocumentHandle,
        handle: u32,
    ) !*SetTimeoutTaskContext {
        const ctx = try allocator.create(SetTimeoutTaskContext);
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .tab = tab,
            .document = document,
            .handle = handle,
        };
        return ctx;
    }

    fn destroy(self: *SetTimeoutTaskContext) void {
        self.allocator.destroy(self);
    }

    fn toOpaque(self: *SetTimeoutTaskContext) *anyopaque {
        return @ptrCast(self);
    }

    fn fromOpaque(context: *anyopaque) *SetTimeoutTaskContext {
        const raw: *align(1) SetTimeoutTaskContext = @ptrCast(context);
        return @alignCast(raw);
    }

    fn runOpaque(context: *anyopaque) anyerror!void {
        try SetTimeoutTaskContext.fromOpaque(context).run();
    }

    fn cleanupOpaque(context: *anyopaque) void {
        SetTimeoutTaskContext.fromOpaque(context).destroy();
    }

    fn run(self: *SetTimeoutTaskContext) !void {
        const frame = self.document.resolve(self.tab) orelse return;
        const trace_eval = self.browser.measure.begin("evaljs");
        defer if (trace_eval) self.browser.measure.end("evaljs");
        const js_context = frame.js_context orelse return;
        js_context.runTimeoutCallback(self.document.window_id, self.handle) catch |err| {
            std.log.warn("setTimeout callback failed: {}", .{err});
        };
    }
};

const AnimationTimerContext = struct {
    browser: *Browser,
    tab: *Tab,

    fn create(browser: *Browser, tab: *Tab) !*AnimationTimerContext {
        const ctx = try browser.allocator.create(AnimationTimerContext);
        ctx.* = .{ .browser = browser, .tab = tab };
        return ctx;
    }

    fn destroy(self: *AnimationTimerContext) void {
        self.browser.allocator.destroy(self);
    }
};

fn runAnimationTimerThread(ctx: *AnimationTimerContext) void {
    const browser = ctx.browser;
    const tab = ctx.tab;
    defer {
        ctx.destroy();
        tab.releaseAsyncThread();
    }

    _ = browser.measure.registerThread("Animation timer thread") catch |err| {
        std.log.warn("Failed to register animation timer thread: {}", .{err});
    };

    browser.io.sleep(.fromNanoseconds(refresh_rate_ns), .awake) catch return;

    browser.lock.lock();
    // Check if browser is shutting down before accessing any resources
    if (browser.shutting_down) {
        browser.animation_timer_active = false;
        browser.lock.unlock();
        return;
    }
    const active_tab = browser.activeTab() orelse {
        browser.animation_timer_active = false;
        browser.lock.unlock();
        return;
    };
    if (active_tab != tab or tab.isShuttingDown()) {
        browser.animation_timer_active = false;
        browser.lock.unlock();
        return;
    }
    const scroll = browser.active_tab_scroll;
    browser.lock.unlock();

    const render_ctx = AnimationRenderTaskContext.create(
        browser.allocator,
        browser,
        tab,
        scroll,
    ) catch |err| {
        std.log.warn("Failed to allocate animation task: {}", .{err});
        browser.lock.lock();
        browser.animation_timer_active = false;
        browser.lock.unlock();
        return;
    };

    const task = Task.init(
        render_ctx.toOpaque(),
        AnimationRenderTaskContext.runOpaque,
        AnimationRenderTaskContext.cleanupOpaque,
    );

    tab.task_runner.schedule(task) catch |err| {
        std.log.warn("Failed to schedule animation frame: {}", .{err});
        render_ctx.destroy();
        browser.lock.lock();
        browser.animation_timer_active = false;
        browser.lock.unlock();
        return;
    };
}

const AnimationRenderTaskContext = struct {
    allocator: std.mem.Allocator,
    browser: *Browser,
    tab: *Tab,
    scroll: i32,

    fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        tab: *Tab,
        scroll: i32,
    ) !*AnimationRenderTaskContext {
        const ctx = try allocator.create(AnimationRenderTaskContext);
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .tab = tab,
            .scroll = scroll,
        };
        return ctx;
    }

    fn destroy(self: *AnimationRenderTaskContext) void {
        self.allocator.destroy(self);
    }

    fn toOpaque(self: *AnimationRenderTaskContext) *anyopaque {
        return @ptrCast(self);
    }

    fn fromOpaque(context: *anyopaque) *AnimationRenderTaskContext {
        const raw: *align(1) AnimationRenderTaskContext = @ptrCast(context);
        return @alignCast(raw);
    }

    fn runOpaque(context: *anyopaque) anyerror!void {
        try AnimationRenderTaskContext.fromOpaque(context).run();
    }

    fn cleanupOpaque(context: *anyopaque) void {
        AnimationRenderTaskContext.fromOpaque(context).destroy();
    }

    fn run(self: *AnimationRenderTaskContext) !void {
        if (self.tab.isShuttingDown()) return;
        self.tab.runAnimationFrame(self.scroll);

        self.browser.lock.lock();
        const should_clear = self.browser.animation_timer_active;
        const should_reschedule = self.browser.needs_animation_frame;
        if (should_clear) {
            self.browser.animation_timer_active = false;
        }
        self.browser.lock.unlock();
        if (should_clear and should_reschedule) {
            self.browser.scheduleAnimationFrame();
        }
    }
};

const XhrThreadContext = struct {
    allocator: std.mem.Allocator,
    browser: *Browser,
    tab: *Tab,
    document: DocumentHandle,
    resolved_url: Url,
    referrer: ?Url,
    referrer_policy: url_module.ReferrerPolicy,
    payload: ?[]const u8,
    handle: u32,

    fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        tab: *Tab,
        document: DocumentHandle,
        resolved_url: Url,
        referrer: ?Url,
        referrer_policy: url_module.ReferrerPolicy,
        payload: ?[]const u8,
        handle: u32,
    ) !*XhrThreadContext {
        const ctx = try allocator.create(XhrThreadContext);
        errdefer allocator.destroy(ctx);

        const payload_copy = if (payload) |body| blk: {
            const copy = try allocator.alloc(u8, body.len);
            @memcpy(copy, body);
            break :blk copy;
        } else null;
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .tab = tab,
            .document = document,
            .resolved_url = resolved_url,
            .referrer = referrer,
            .referrer_policy = referrer_policy,
            .payload = payload_copy,
            .handle = handle,
        };

        return ctx;
    }

    fn destroy(self: *XhrThreadContext) void {
        if (self.payload) |body| {
            self.allocator.free(body);
        }
        self.resolved_url.free(self.allocator);
        if (self.referrer) |referrer| referrer.free(self.allocator);
        self.allocator.destroy(self);
    }
};

fn ownedXhrRequestOrigin(
    allocator: std.mem.Allocator,
    resolved_url: Url,
    referrer: ?Url,
) !?[]u8 {
    const source = referrer orelse return null;
    if (source.sameOrigin(resolved_url)) return null;
    return try source.toOwnedOrigin(allocator);
}

fn freeRawXhrBody(allocator: std.mem.Allocator, url: Url, body: []const u8) void {
    if (!std.mem.eql(u8, url.scheme, "about") and
        !std.mem.eql(u8, url.scheme, "data"))
    {
        allocator.free(body);
    }
}

fn runXhrThread(ctx: *XhrThreadContext) void {
    const tab = ctx.tab;
    defer {
        ctx.destroy();
        tab.releaseAsyncThread();
    }

    _ = ctx.browser.measure.registerThread("XHR thread") catch |err| {
        std.log.warn("Failed to register XHR thread: {}", .{err});
    };

    const request_origin = ownedXhrRequestOrigin(
        ctx.allocator,
        ctx.resolved_url,
        ctx.referrer,
    ) catch |err| {
        std.log.warn("Failed to serialize async XHR origin: {}", .{err});
        return;
    };
    defer if (request_origin) |origin| ctx.allocator.free(origin);

    const response_result = (if (request_origin) |origin|
        ctx.browser.fetchBodyWithOrigin(
            ctx.resolved_url,
            ctx.referrer,
            ctx.payload,
            origin,
            ctx.referrer_policy,
        )
    else
        ctx.browser.fetchBodyWithReferrerPolicy(
            ctx.resolved_url,
            ctx.referrer,
            ctx.payload,
            ctx.referrer_policy,
        )) catch |err| {
        std.log.warn("Async XHR failed: {}", .{err});
        return;
    };
    defer if (response_result.csp_header) |hdr| ctx.allocator.free(hdr);
    defer if (response_result.access_control_allow_origin) |hdr| ctx.allocator.free(hdr);

    if (!url_module.corsAllowsResponse(
        request_origin,
        response_result.access_control_allow_origin,
    )) {
        freeRawXhrBody(ctx.allocator, ctx.resolved_url, response_result.body);
        std.log.warn("Discarded cross-origin XHR response without matching Access-Control-Allow-Origin", .{});
        return;
    }

    var response_body = response_result.body;
    var should_free_response = true;
    var response_allocator: ?std.mem.Allocator = ctx.allocator;

    if (std.mem.eql(u8, ctx.resolved_url.scheme, "about")) {
        should_free_response = false;
        response_allocator = null;
    } else if (std.mem.eql(u8, ctx.resolved_url.scheme, "data")) {
        const copy = ctx.allocator.alloc(u8, response_body.len) catch {
            std.log.warn("Failed to copy async XHR data body", .{});
            return;
        };
        @memcpy(copy, response_body);
        response_body = copy;
        response_allocator = ctx.allocator;
    }

    const decoded_body = decodeUtf8Replace(ctx.allocator, response_body) catch |err| {
        std.log.warn("Failed to decode XHR body: {}", .{err});
        if (should_free_response) {
            if (response_allocator) |alloc| {
                alloc.free(response_body);
            } else {
                ctx.allocator.free(response_body);
            }
        }
        return;
    };

    if (should_free_response) {
        if (response_allocator) |alloc| {
            alloc.free(response_body);
        } else {
            ctx.allocator.free(response_body);
        }
    }

    const task_ctx = XhrOnloadTaskContext.create(
        ctx.allocator,
        ctx.browser,
        tab,
        ctx.document,
        ctx.handle,
        decoded_body,
        ctx.allocator,
        true,
    ) catch |err| {
        std.log.warn("Failed to enqueue XHR onload task: {}", .{err});
        ctx.allocator.free(decoded_body);
        return;
    };

    const task = Task.init(
        task_ctx.toOpaque(),
        XhrOnloadTaskContext.runOpaque,
        XhrOnloadTaskContext.cleanupOpaque,
    );

    tab.task_runner.schedule(task) catch |err| {
        std.log.warn("Failed to schedule XHR onload task: {}", .{err});
        task_ctx.destroy();
    };
}

const XhrOnloadTaskContext = struct {
    allocator: std.mem.Allocator,
    browser: *Browser,
    tab: *Tab,
    document: DocumentHandle,
    handle: u32,
    body: []const u8,
    body_allocator: ?std.mem.Allocator,
    should_free_body: bool,

    fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        tab: *Tab,
        document: DocumentHandle,
        handle: u32,
        body: []const u8,
        body_allocator: ?std.mem.Allocator,
        should_free_body: bool,
    ) !*XhrOnloadTaskContext {
        const ctx = try allocator.create(XhrOnloadTaskContext);
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .tab = tab,
            .document = document,
            .handle = handle,
            .body = body,
            .body_allocator = body_allocator,
            .should_free_body = should_free_body,
        };
        return ctx;
    }

    fn destroy(self: *XhrOnloadTaskContext) void {
        if (self.should_free_body) {
            if (self.body_allocator) |alloc| {
                alloc.free(self.body);
            } else {
                self.allocator.free(self.body);
            }
        }
        self.allocator.destroy(self);
    }

    fn toOpaque(self: *XhrOnloadTaskContext) *anyopaque {
        return @ptrCast(self);
    }

    fn fromOpaque(context: *anyopaque) *XhrOnloadTaskContext {
        const raw: *align(1) XhrOnloadTaskContext = @ptrCast(context);
        return @alignCast(raw);
    }

    fn runOpaque(context: *anyopaque) anyerror!void {
        try XhrOnloadTaskContext.fromOpaque(context).run();
    }

    fn cleanupOpaque(context: *anyopaque) void {
        XhrOnloadTaskContext.fromOpaque(context).destroy();
    }

    fn run(self: *XhrOnloadTaskContext) !void {
        const frame = self.document.resolve(self.tab) orelse return;
        const js_context = frame.js_context orelse return;
        js_context.runXhrOnload(self.document.window_id, self.handle, self.body) catch |err| {
            std.log.warn("XHR onload callback failed: {}", .{err});
        };
    }
};

fn jsRenderCallback(context: ?*anyopaque) anyerror!void {
    const ctx_ptr = context orelse return;
    const raw_ctx: *align(1) JsRenderContext = @ptrCast(ctx_ptr);
    const ctx: *JsRenderContext = @alignCast(raw_ctx);

    const browser_ptr = ctx.browser_ptr orelse return;
    const tab_ptr = ctx.tab_ptr orelse return;

    const raw_browser: *align(1) Browser = @ptrCast(browser_ptr);
    const browser: *Browser = @alignCast(raw_browser);

    const raw_tab: *align(1) Tab = @ptrCast(tab_ptr);
    const tab: *Tab = @alignCast(raw_tab);

    // Mark render work; let the main loop drive rendering to avoid re-entrancy.
    _ = browser;
    tab.setNeedsRender();
}

fn jsDomMutationCallback(context: ?*anyopaque, mutation_root: *parser.Node) void {
    const ctx_ptr = context orelse return;
    const raw_ctx: *align(1) JsRenderContext = @ptrCast(ctx_ptr);
    const ctx: *JsRenderContext = @alignCast(raw_ctx);

    const browser_ptr = ctx.browser_ptr orelse return;
    const tab_ptr = ctx.tab_ptr orelse return;
    const raw_browser: *align(1) Browser = @ptrCast(browser_ptr);
    const browser: *Browser = @alignCast(raw_browser);
    const raw_tab: *align(1) Tab = @ptrCast(tab_ptr);
    const tab: *Tab = @alignCast(raw_tab);

    const frame = tab.frameForWindowId(ctx.window_id) orelse return;
    if (frame.document_generation == 0 or
        !ctx.matchesGeneration(frame.document_generation)) return;

    tab.prepareForDomMutation(browser, frame, mutation_root);
}

fn jsCookieGetCallback(context: ?*anyopaque) anyerror!js_module.CookieResult {
    const ctx_ptr = context orelse return error.MissingJsContext;
    const raw_ctx: *align(1) JsRenderContext = @ptrCast(ctx_ptr);
    const ctx: *JsRenderContext = @alignCast(raw_ctx);
    const browser_ptr = ctx.browser_ptr orelse return error.MissingJsContext;
    const tab_ptr = ctx.tab_ptr orelse return error.MissingJsContext;
    const raw_browser: *align(1) Browser = @ptrCast(browser_ptr);
    const browser: *Browser = @alignCast(raw_browser);
    const raw_tab: *align(1) Tab = @ptrCast(tab_ptr);
    const tab: *Tab = @alignCast(raw_tab);
    const frame = tab.frameForWindowId(ctx.window_id) orelse return error.MissingJsContext;
    if (frame.document_generation == 0 or
        !ctx.matchesGeneration(frame.document_generation)) return error.StaleDocument;
    const current_url = frame.current_url orelse return .{ .data = "" };
    const host = current_url.host orelse return .{ .data = "" };

    const data = try browser.session_state.readCookieForScript(browser.allocator, host);
    return .{
        .data = data,
        .allocator = browser.allocator,
        .should_free = true,
    };
}

fn jsCookieSetCallback(context: ?*anyopaque, value: []const u8) anyerror!void {
    const ctx_ptr = context orelse return error.MissingJsContext;
    const raw_ctx: *align(1) JsRenderContext = @ptrCast(ctx_ptr);
    const ctx: *JsRenderContext = @alignCast(raw_ctx);
    const browser_ptr = ctx.browser_ptr orelse return error.MissingJsContext;
    const tab_ptr = ctx.tab_ptr orelse return error.MissingJsContext;
    const raw_browser: *align(1) Browser = @ptrCast(browser_ptr);
    const browser: *Browser = @alignCast(raw_browser);
    const raw_tab: *align(1) Tab = @ptrCast(tab_ptr);
    const tab: *Tab = @alignCast(raw_tab);
    const frame = tab.frameForWindowId(ctx.window_id) orelse return error.MissingJsContext;
    if (frame.document_generation == 0 or
        !ctx.matchesGeneration(frame.document_generation)) return error.StaleDocument;
    const current_url = frame.current_url orelse return;
    const host = current_url.host orelse return;
    _ = try browser.session_state.writeCookieFromScript(host, value);
}

fn jsXhrCallback(
    context: ?*anyopaque,
    _: []const u8,
    url_str: []const u8,
    body: ?[]const u8,
    is_async: bool,
    handle: u32,
) anyerror!js_module.XhrResult {
    const ctx_ptr = context orelse return error.MissingJsContext;
    const raw_ctx: *align(1) JsRenderContext = @ptrCast(ctx_ptr);
    const ctx: *JsRenderContext = @alignCast(raw_ctx);

    const browser_ptr = ctx.browser_ptr orelse return error.MissingJsContext;
    const tab_ptr = ctx.tab_ptr orelse return error.MissingJsContext;

    const raw_browser: *align(1) Browser = @ptrCast(browser_ptr);
    const browser: *Browser = @alignCast(raw_browser);

    const raw_tab: *align(1) Tab = @ptrCast(tab_ptr);
    const tab: *Tab = @alignCast(raw_tab);
    const frame = tab.frameForWindowId(ctx.window_id) orelse return error.MissingJsContext;

    const allocator = browser.allocator;
    var resolved_url: Url = undefined;
    if (frame.current_url) |current_ptr| {
        resolved_url = current_ptr.*.resolve(allocator, url_str) catch |err| blk: {
            std.log.warn("Failed to resolve XHR URL {s} relative to page: {}", .{ url_str, err });
            break :blk try Url.init(allocator, url_str);
        };
    } else {
        resolved_url = try Url.init(allocator, url_str);
    }

    defer resolved_url.free(allocator);

    if (!frame.allowedRequest(resolved_url, frame.current_url)) {
        const target_host = resolved_url.host orelse "";
        std.log.warn(
            "Blocked XHR to {s}://{s}:{d} due to CSP",
            .{ resolved_url.scheme, target_host, resolved_url.port },
        );
        return error.CspViolation;
    }

    var current_url_value: ?Url = null;
    if (frame.current_url) |cur_ptr| {
        current_url_value = cur_ptr.*;
    }

    if (is_async) {
        try browser.scheduleAsyncXhr(
            tab,
            ctx,
            resolved_url,
            current_url_value,
            frame.referrer_policy,
            body,
            handle,
        );
        return .{ .data = "", .allocator = null, .should_free = false };
    }

    const request_origin = try ownedXhrRequestOrigin(allocator, resolved_url, current_url_value);
    defer if (request_origin) |origin| allocator.free(origin);

    const response = if (request_origin) |origin|
        try browser.fetchBodyWithOrigin(
            resolved_url,
            current_url_value,
            body,
            origin,
            frame.referrer_policy,
        )
    else
        try browser.fetchBodyWithReferrerPolicy(
            resolved_url,
            current_url_value,
            body,
            frame.referrer_policy,
        );
    defer if (response.csp_header) |hdr| allocator.free(hdr);
    defer if (response.access_control_allow_origin) |hdr| allocator.free(hdr);

    if (!url_module.corsAllowsResponse(request_origin, response.access_control_allow_origin)) {
        freeRawXhrBody(allocator, resolved_url, response.body);
        return error.CrossOriginBlocked;
    }

    var response_body = response.body;

    var should_free_response = true;
    var response_allocator: ?std.mem.Allocator = allocator;

    if (std.mem.eql(u8, resolved_url.scheme, "data")) {
        const copy = try allocator.alloc(u8, response_body.len);
        @memcpy(copy, response_body);
        response_body = copy;
    } else if (std.mem.eql(u8, resolved_url.scheme, "about")) {
        should_free_response = false;
        response_allocator = null;
    }

    const decoded_body = decodeUtf8Replace(allocator, response_body) catch |err| {
        if (should_free_response) {
            if (response_allocator) |alloc| {
                alloc.free(response_body);
            } else {
                allocator.free(response_body);
            }
        }
        return err;
    };

    if (should_free_response) {
        if (response_allocator) |alloc| {
            alloc.free(response_body);
        } else {
            allocator.free(response_body);
        }
    }

    return .{
        .data = decoded_body,
        .allocator = allocator,
        .should_free = true,
    };
}

fn jsSetTimeoutCallback(
    context: ?*anyopaque,
    handle: u32,
    delay_ms: u32,
) anyerror!void {
    const ctx_ptr = context orelse return error.MissingJsContext;
    const raw_ctx: *align(1) JsRenderContext = @ptrCast(ctx_ptr);
    const ctx: *JsRenderContext = @alignCast(raw_ctx);

    const browser_ptr = ctx.browser_ptr orelse return error.MissingJsContext;
    const tab_ptr = ctx.tab_ptr orelse return error.MissingJsContext;

    const raw_browser: *align(1) Browser = @ptrCast(browser_ptr);
    const browser: *Browser = @alignCast(raw_browser);

    const raw_tab: *align(1) Tab = @ptrCast(tab_ptr);
    const tab: *Tab = @alignCast(raw_tab);

    try browser.scheduleSetTimeoutTask(tab, ctx, handle, delay_ms);
}

fn jsRequestAnimationFrameCallback(
    context: ?*anyopaque,
) anyerror!void {
    const ctx_ptr = context orelse return error.MissingJsContext;
    const raw_ctx: *align(1) JsRenderContext = @ptrCast(ctx_ptr);
    const ctx: *JsRenderContext = @alignCast(raw_ctx);

    const tab_ptr = ctx.tab_ptr orelse return error.MissingJsContext;

    const raw_tab: *align(1) Tab = @ptrCast(tab_ptr);
    const tab: *Tab = @alignCast(raw_tab);

    tab.setNeedsRender();
}

fn originStringForUrl(allocator: std.mem.Allocator, url: Url) ![]u8 {
    if (std.mem.eql(u8, url.scheme, "file")) {
        return allocator.dupe(u8, "file://");
    }
    if (std.mem.eql(u8, url.scheme, "about") or std.mem.eql(u8, url.scheme, "data")) {
        return std.fmt.allocPrint(allocator, "{s}:", .{url.scheme});
    }
    const host = url.host orelse "";
    return std.fmt.allocPrint(allocator, "{s}://{s}:{d}", .{ url.scheme, host, url.port });
}

fn normalizeOrigin(allocator: std.mem.Allocator, origin: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, origin, " \t\r\n");
    const lower = try allocator.alloc(u8, trimmed.len);
    for (trimmed, 0..) |ch, idx| {
        lower[idx] = std.ascii.toLower(ch);
    }
    return lower;
}

fn jsPostMessageCallback(
    context: ?*anyopaque,
    source_window_id: u32,
    target_window_id: u32,
    target_origin: []const u8,
    message: []const u8,
) anyerror!void {
    const ctx_ptr = context orelse return error.MissingJsContext;
    const raw_ctx: *align(1) JsRenderContext = @ptrCast(ctx_ptr);
    const ctx: *JsRenderContext = @alignCast(raw_ctx);

    const browser_ptr = ctx.browser_ptr orelse return error.MissingJsContext;
    const tab_ptr = ctx.tab_ptr orelse return error.MissingJsContext;

    const raw_browser: *align(1) Browser = @ptrCast(browser_ptr);
    const browser: *Browser = @alignCast(raw_browser);

    const raw_tab: *align(1) Tab = @ptrCast(tab_ptr);
    const tab: *Tab = @alignCast(raw_tab);

    const source_frame = tab.frameForWindowId(source_window_id) orelse return;
    const target_frame = tab.frameForWindowId(target_window_id) orelse return;

    const allocator = browser.allocator;

    var source_origin = try allocator.dupe(u8, "null");
    defer allocator.free(source_origin);
    if (source_frame.current_url) |url_ptr| {
        allocator.free(source_origin);
        source_origin = try originStringForUrl(allocator, url_ptr.*);
    }

    if (!std.mem.eql(u8, target_origin, "*")) {
        var target_origin_actual = try allocator.dupe(u8, "null");
        defer allocator.free(target_origin_actual);
        if (target_frame.current_url) |url_ptr| {
            allocator.free(target_origin_actual);
            target_origin_actual = try originStringForUrl(allocator, url_ptr.*);
        }

        const target_origin_norm = try normalizeOrigin(allocator, target_origin);
        defer allocator.free(target_origin_norm);
        const actual_origin_norm = try normalizeOrigin(allocator, target_origin_actual);
        defer allocator.free(actual_origin_norm);

        if (!std.mem.eql(u8, target_origin_norm, actual_origin_norm)) {
            std.log.warn("Blocked postMessage due to target origin mismatch", .{});
            return;
        }
    }

    const task_ctx = try PostMessageTaskContext.create(
        allocator,
        browser,
        tab,
        DocumentHandle.fromFrame(target_frame),
        source_window_id,
        message,
        source_origin,
    );
    const task = Task.init(
        task_ctx.toOpaque(),
        PostMessageTaskContext.runOpaque,
        PostMessageTaskContext.cleanupOpaque,
    );
    tab.task_runner.schedule(task) catch |err| {
        std.log.warn("Failed to schedule postMessage task: {}", .{err});
        task_ctx.destroy();
    };
}

const PostMessageTaskContext = struct {
    allocator: std.mem.Allocator,
    browser: *Browser,
    tab: *Tab,
    target_document: DocumentHandle,
    source_window_id: u32,
    message: []const u8,
    origin: []const u8,

    fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        tab: *Tab,
        target_document: DocumentHandle,
        source_window_id: u32,
        message: []const u8,
        origin: []const u8,
    ) !*PostMessageTaskContext {
        const ctx = try allocator.create(PostMessageTaskContext);
        const message_copy = try allocator.dupe(u8, message);
        errdefer allocator.free(message_copy);
        const origin_copy = try allocator.dupe(u8, origin);
        errdefer allocator.free(origin_copy);
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .tab = tab,
            .target_document = target_document,
            .source_window_id = source_window_id,
            .message = message_copy,
            .origin = origin_copy,
        };
        return ctx;
    }

    fn destroy(self: *PostMessageTaskContext) void {
        self.allocator.free(self.message);
        self.allocator.free(self.origin);
        self.allocator.destroy(self);
    }

    fn toOpaque(self: *PostMessageTaskContext) *anyopaque {
        return @ptrCast(self);
    }

    fn fromOpaque(context: *anyopaque) *PostMessageTaskContext {
        const raw: *align(1) PostMessageTaskContext = @ptrCast(context);
        return @alignCast(raw);
    }

    fn runOpaque(context: *anyopaque) anyerror!void {
        try PostMessageTaskContext.fromOpaque(context).run();
    }

    fn cleanupOpaque(context: *anyopaque) void {
        PostMessageTaskContext.fromOpaque(context).destroy();
    }

    fn run(self: *PostMessageTaskContext) !void {
        const target_frame = self.target_document.resolve(self.tab) orelse return;
        const target_context = target_frame.js_context orelse return;
        target_context.dispatchPostMessage(
            self.target_document.window_id,
            self.message,
            self.origin,
            self.source_window_id,
        ) catch |err| {
            std.log.warn("Failed to dispatch postMessage: {}", .{err});
            return;
        };
        // Ensure postMessage-driven DOM updates paint without waiting for input.
        self.tab.setNeedsRender();
        const scroll = if (self.tab.root_frame) |root| root.scroll else 0;
        self.tab.runAnimationFrame(scroll);
    }
};
