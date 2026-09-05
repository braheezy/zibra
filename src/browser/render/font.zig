//! Discovers fonts and supplies measured, rasterized glyphs to layout and paint.
//!
//! The font manager wraps SDL_ttf, selects system-font fallbacks by character
//! category and style, and caches owned RGBA glyph bitmaps.

const std = @import("std");
const builtin = @import("builtin");

const code_point = @import("code_point");
const unicode_emoji = @import("emoji");
const sdl2 = @import("sdl");

const hyphen_codepoint = 0x00AD;
const rgba_surface_format = if (builtin.target.cpu.arch.endian() == .big)
    sdl2.c.SDL_PIXELFORMAT_RGBA8888
else
    sdl2.c.SDL_PIXELFORMAT_ABGR8888;

pub const FontWeight = enum {
    Normal,
    Bold,
};

pub const FontSlant = enum {
    Roman,
    Italic,
};

pub const FontCategory = enum {
    latin,
    cjk,
    symbols,
    emoji,
    monospace,
};

/// The CSS family choices supported by Zibra's bundled system-font set.
/// Named monospace faces such as Courier resolve to the platform's available
/// monospace face; the proportional choice continues to use Unicode-specific
/// fallback faces for CJK, symbols, and emoji.
pub const FontFamily = enum {
    proportional,
    monospace,
};

const UnicodeRange = struct {
    start: u21,
    end: u21,
};

const FontCategoryRanges = struct {
    latin: []const UnicodeRange,
    cjk: []const UnicodeRange,
};

const unicode_ranges = FontCategoryRanges{
    .latin = &[_]UnicodeRange{
        .{ .start = 0x0000, .end = 0x024F }, // Basic Latin + Latin-1 Supplement
        .{ .start = 0x1E00, .end = 0x1EFF }, // Latin Extended Additional
        .{ .start = 0x2000, .end = 0x206F }, // General Punctuation
    },
    .cjk = &[_]UnicodeRange{
        .{ .start = 0x4E00, .end = 0x9FFF }, // CJK Unified Ideographs
        .{ .start = 0x3400, .end = 0x4DBF }, // CJK Unified Ideographs Extension A
        .{ .start = 0x3000, .end = 0x303F }, // CJK Symbols and Punctuation
        .{ .start = 0xFF00, .end = 0xFFEF }, // Fullwidth Forms
        .{ .start = 0x3040, .end = 0x309F }, // Hiragana
        .{ .start = 0x30A0, .end = 0x30FF }, // Katakana
        .{ .start = 0xAC00, .end = 0xD7A3 }, // Hangul Syllables
    },
};

const FontEntry = struct {
    name: []const u8,
    category: FontCategory,
    weight: FontWeight,
    slant: FontSlant,
};

const system_fonts = switch (builtin.target.os.tag) {
    .macos => struct {
        paths: []const []const u8,
        fonts: []const FontEntry,
    }{
        .paths = &[_][]const u8{
            "/Library/Fonts",
            "/System/Library/Fonts",
            "/System/Library/Fonts/Supplemental",
        },
        .fonts = &[_]FontEntry{
            .{
                .name = "Arial",
                .category = .latin,
                .weight = .Normal,
                .slant = .Roman,
            },
            .{
                .name = "Arial Unicode",
                .category = .cjk,
                .weight = .Normal,
                .slant = .Roman,
            },
            .{
                .name = "Apple Symbols",
                .category = .symbols,
                .weight = .Normal,
                .slant = .Roman,
            },
            .{
                .name = "Apple Color Emoji",
                .category = .emoji,
                .weight = .Normal,
                .slant = .Roman,
            },
            .{
                .name = "Arial Bold",
                .category = .latin,
                .weight = .Bold,
                .slant = .Roman,
            },
            .{
                .name = "Arial Italic",
                .category = .latin,
                .weight = .Normal,
                .slant = .Italic,
            },
            .{
                .name = "Arial Bold Italic",
                .category = .latin,
                .weight = .Bold,
                .slant = .Italic,
            },
            .{
                .name = "Andale Mono",
                .category = .monospace,
                .weight = .Normal,
                .slant = .Roman,
            },
            .{
                .name = "Andale Mono",
                .category = .monospace,
                .weight = .Normal,
                .slant = .Italic,
            },
        },
    },
    .linux => struct {
        paths: []const []const u8,
        fonts: []const FontEntry,
    }{
        .paths = &[_][]const u8{
            "/usr/share/fonts",
            "/usr/local/share/fonts",
            "/usr/share/fonts/google-noto",
            "/usr/share/fonts/google-noto-sans-cjk-vf-fonts",
            "/usr/share/fonts/google-noto-color-emoji-fonts",
            "/usr/share/fonts/truetype/noto",
            "/usr/share/fonts/opentype/noto",
            "/usr/share/fonts/noto",
            "/usr/share/fonts/twemoji",
        },
        .fonts = &[_]FontEntry{
            .{
                .name = "NotoSans-Regular",
                .category = .latin,
                .weight = .Normal,
                .slant = .Roman,
            },
            .{
                .name = "NotoSans-Bold",
                .category = .latin,
                .weight = .Bold,
                .slant = .Roman,
            },
            .{
                .name = "NotoSans-Italic",
                .category = .latin,
                .weight = .Normal,
                .slant = .Italic,
            },
            .{
                .name = "NotoSans-BoldItalic",
                .category = .latin,
                .weight = .Bold,
                .slant = .Italic,
            },

            .{
                .name = "NotoSansCJK-VF",
                .category = .cjk,
                .weight = .Normal,
                .slant = .Roman,
            },
            .{
                .name = "NotoSansSymbols2-Regular",
                .category = .symbols,
                .weight = .Normal,
                .slant = .Roman,
            },
            .{
                .name = "NotoColorEmoji",
                .category = .emoji,
                .weight = .Normal,
                .slant = .Roman,
            },
            .{
                .name = "DejaVuSansMono",
                .category = .monospace,
                .weight = .Normal,
                .slant = .Roman,
            },
            .{
                .name = "DejaVuSansMono-Bold",
                .category = .monospace,
                .weight = .Bold,
                .slant = .Roman,
            },
            .{
                .name = "DejaVuSansMono-Oblique",
                .category = .monospace,
                .weight = .Normal,
                .slant = .Italic,
            },
            .{
                .name = "DejaVuSansMono-BoldOblique",
                .category = .monospace,
                .weight = .Bold,
                .slant = .Italic,
            },
        },
    },
    else => @compileError("Unsupported operating system"),
};

fn homeDirectory(environ: *const std.process.Environ.Map) ?[]const u8 {
    const home = environ.get("HOME") orelse return null;
    return if (home.len == 0) null else home;
}

fn configuredFontCategory(name: []const u8) FontCategory {
    for (system_fonts.fonts) |font| {
        if (std.mem.eql(u8, font.name, name)) return font.category;
    }
    return .latin;
}

pub const GlyphPixelMode = enum {
    alpha_mask,
    color,
};

pub const Glyph = struct {
    w: i32,
    h: i32,
    ascent: i32,
    descent: i32,
    is_superscript: bool = false,
    is_soft_hyphen: bool = false,
    pixel_mode: GlyphPixelMode = .alpha_mask,
    /// Owned by the FontManager cache and borrowed by display-list snapshots.
    /// The dimensions always match `w` and `h` exactly.
    pixels: ?[]u8 = null,
};

fn emojiWidthForHeight(source_width: i32, source_height: i32, target_height: i32) i32 {
    if (source_width <= 0 or source_height <= 0 or target_height <= 0) return 0;
    const numerator = @as(i64, source_width) * target_height + @divTrunc(source_height, 2);
    const scaled = @divTrunc(numerator, source_height);
    return @intCast(@min(@max(scaled, 1), @as(i64, std.math.maxInt(i32))));
}

/// SDL_ttf's default 72-DPI face size maps one input unit to one pixel.
/// CSS lengths are already pixels; converting them to points would shrink
/// every authored font by 25%. Native display density is separate.
pub fn rasterSizeForCssPixels(pixels: f64) i32 {
    if (!std.math.isFinite(pixels)) return 16;
    return @intFromFloat(std.math.clamp(@round(pixels), 1, 4096));
}

/// Shared face selection for intrinsic measurement and final glyph layout.
pub fn isBoldWeight(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "bold") or std.ascii.eqlIgnoreCase(trimmed, "bolder")) return true;
    const numeric = std.fmt.parseInt(u16, trimmed, 10) catch return false;
    return numeric >= 600;
}

test "CSS font pixels are not converted to typographic points" {
    try std.testing.expectEqual(@as(i32, 16), rasterSizeForCssPixels(16));
    try std.testing.expectEqual(@as(i32, 13), rasterSizeForCssPixels(13));
    try std.testing.expectEqual(@as(i32, 24), rasterSizeForCssPixels(24));
    try std.testing.expectEqual(@as(i32, 14), rasterSizeForCssPixels(13.6));
}

fn emojiHeightForFontSize(font_size: i32) i32 {
    return @max(font_size, 0);
}

fn copySurfaceRgba(
    allocator: std.mem.Allocator,
    surface: sdl2.Surface,
    target_width: i32,
    target_height: i32,
) ![]u8 {
    if (target_width <= 0 or target_height <= 0) return error.InvalidGlyphDimensions;

    const converted_ptr = sdl2.c.SDL_ConvertSurfaceFormat(
        surface.ptr,
        rgba_surface_format,
        0,
    ) orelse return sdl2.makeError();
    const converted = sdl2.Surface{ .ptr = converted_ptr };
    defer converted.destroy();

    var resized: ?sdl2.Surface = null;
    defer if (resized) |value| value.destroy();

    const output_ptr = if (converted.ptr.w == target_width and converted.ptr.h == target_height)
        converted.ptr
    else blk: {
        const resized_ptr = sdl2.c.SDL_CreateRGBSurfaceWithFormat(
            0,
            target_width,
            target_height,
            32,
            rgba_surface_format,
        ) orelse return sdl2.makeError();
        resized = .{ .ptr = resized_ptr };
        if (sdl2.c.SDL_SoftStretchLinear(converted.ptr, null, resized_ptr, null) < 0) {
            return sdl2.makeError();
        }
        break :blk resized_ptr;
    };

    const pixels_ptr = output_ptr.pixels orelse return error.MissingGlyphPixels;
    const width: usize = @intCast(target_width);
    const height: usize = @intCast(target_height);
    const row_bytes = width * 4;
    const pitch: usize = @intCast(output_ptr.pitch);
    if (pitch < row_bytes) return error.InvalidGlyphPitch;

    const pixels = try allocator.alloc(u8, row_bytes * height);
    errdefer allocator.free(pixels);
    const source: [*]const u8 = @ptrCast(pixels_ptr);
    for (0..height) |y| {
        @memcpy(
            pixels[y * row_bytes ..][0..row_bytes],
            source[y * pitch ..][0..row_bytes],
        );
    }
    return pixels;
}

const Font = struct {
    category: FontCategory,
    font_handle: sdl2.ttf.Font,
    glyphs: std.AutoHashMap(u64, Glyph),
};

const FontKey = struct {
    category: FontCategory,
    weight: FontWeight,
    slant: FontSlant,
};

pub const FontManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    fonts: std.StringHashMap(*Font),
    styled_fonts: std.AutoHashMap(FontKey, *Font),
    category_fonts: std.AutoHashMap(FontCategory, *Font),
    current_font: ?*Font = null,
    loaded_sizes: std.AutoHashMap(i32, void),

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ: *const std.process.Environ.Map,
    ) !FontManager {
        try sdl2.ttf.init();

        return FontManager{
            .allocator = allocator,
            .io = io,
            .environ = environ,
            .fonts = std.StringHashMap(*Font).init(allocator),
            .styled_fonts = std.AutoHashMap(FontKey, *Font).init(allocator),
            .category_fonts = std.AutoHashMap(FontCategory, *Font).init(allocator),
            .loaded_sizes = std.AutoHashMap(i32, void).init(allocator),
        };
    }

    pub fn deinit(self: *FontManager) void {
        var fonts_it = self.fonts.iterator();
        while (fonts_it.next()) |entry| {
            var f = entry.value_ptr.*;

            var outer_it = f.glyphs.iterator();
            while (outer_it.next()) |outer_entry| {
                const cache_entry = outer_entry.value_ptr.*;
                if (cache_entry.pixels) |pixels| {
                    self.allocator.free(pixels);
                }
            }
            f.glyphs.deinit();

            f.font_handle.close();
            self.allocator.destroy(f);
        }

        self.styled_fonts.deinit();
        self.category_fonts.deinit();
        self.fonts.deinit();
        self.loaded_sizes.deinit();

        sdl2.ttf.quit();
    }

    fn collectFontPaths(self: *FontManager) !std.ArrayList([]const u8) {
        var paths = std.ArrayList([]const u8).empty;
        errdefer {
            for (paths.items) |path| self.allocator.free(path);
            paths.deinit(self.allocator);
        }

        // Add user font directory first to prefer them.
        const home_dir = homeDirectory(self.environ) orelse return error.NoHomeDir;

        const user_suffixes = switch (builtin.target.os.tag) {
            .macos => &[_][]const u8{"/Library/Fonts"},
            .linux => &[_][]const u8{ "/.local/share/fonts", "/.fonts" },
            else => &[_][]const u8{},
        };
        for (user_suffixes) |suffix| {
            const user_path = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ home_dir, suffix });
            paths.append(self.allocator, user_path) catch |err| {
                self.allocator.free(user_path);
                return err;
            };
        }

        // Add system font directories
        for (system_fonts.paths) |dir| {
            const copy = try self.allocator.dupe(u8, dir);
            paths.append(self.allocator, copy) catch |err| {
                self.allocator.free(copy);
                return err;
            };
        }

        return paths;
    }

    fn tryLoadFontFromPaths(self: *FontManager, name: []const u8, paths: []const []const u8, size: i32) !bool {
        const extensions = [_][]const u8{ ".ttf", ".otf", ".ttc" };

        for (paths) |dir| {
            var dir_path = std.Io.Dir.cwd().openDir(self.io, dir, .{ .iterate = true }) catch continue;
            defer dir_path.close(self.io);

            var dir_entries = dir_path.iterate();
            while (try dir_entries.next(self.io)) |file_entry| {
                if (file_entry.kind != .file) continue;

                const filename = file_entry.name;
                for (extensions) |ext| {
                    if (std.ascii.endsWithIgnoreCase(filename, ext)) {
                        const base_name = filename[0 .. filename.len - ext.len];
                        if (std.ascii.eqlIgnoreCase(base_name, name)) {
                            const font_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, filename });
                            defer self.allocator.free(font_path);

                            return self.loadFontAtPath(font_path, name, size);
                        }
                    }
                }
            }
        }

        return false;
    }

    fn loadFontAtPath(self: *FontManager, path: []const u8, name: []const u8, size: i32) !bool {
        if (self.fonts.get(name)) |_| return true;

        const path_z = try sliceToSentinelArray(self.allocator, path);
        defer self.allocator.free(path_z);

        var fh = sdl2.ttf.openFontIndex(path_z, size, 0) catch return false;

        const font = self.allocator.create(Font) catch |err| {
            fh.close();
            return err;
        };
        var font_owned = true;
        errdefer if (font_owned) {
            font.glyphs.deinit();
            fh.close();
            self.allocator.destroy(font);
        };
        font.* = Font{
            .category = configuredFontCategory(name),
            .font_handle = fh,
            .glyphs = std.AutoHashMap(u64, Glyph).init(self.allocator),
        };

        try self.fonts.put(name, font);
        font_owned = false;

        if (self.current_font == null) {
            self.current_font = self.fonts.get(name);
        }

        // After loading font, find its metadata in system_fonts
        for (system_fonts.fonts) |sf| {
            if (std.mem.eql(u8, sf.name, name)) {
                // Add to styled_fonts map
                const key = FontKey{
                    .category = sf.category,
                    .weight = sf.weight,
                    .slant = sf.slant,
                };
                try self.styled_fonts.put(key, font);

                // If this is a "normal" font (Normal weight, Roman slant),
                // add/update it as the category font
                if (sf.weight == .Normal and sf.slant == .Roman) {
                    try self.category_fonts.put(sf.category, font);
                }
                break;
            }
        }

        return true;
    }

    /// Load all standard system fonts (Latin, CJK, Emoji)
    pub fn loadSystemFont(self: *FontManager, size: i32) !void {
        // Add user font directory to search paths
        var search_paths = try self.collectFontPaths();
        defer {
            for (search_paths.items) |dir| {
                self.allocator.free(dir);
            }
            search_paths.deinit(self.allocator);
        }

        // Iterate through font categories in order of priority
        const categories = [_]FontCategory{ .latin, .cjk, .symbols, .emoji, .monospace };
        for (categories) |category| {
            for (system_fonts.fonts) |font| {
                if (font.category != category) continue; // Skip fonts not matching the current category

                if (try self.tryLoadFontFromPaths(font.name, search_paths.items, size)) {
                    std.log.debug("Loaded {s} font at size {d}: {s}", .{ @tagName(category), size, font.name });
                } else {
                    std.log.warn("Failed to load {s} font: {s}", .{ @tagName(category), font.name });
                }
            }
        }

        // Ensure at least one font is loaded
        if (self.fonts.count() == 0) {
            return error.NoFontsLoaded;
        }

        // Set the current font if not already set
        if (self.current_font == null) {
            var it = self.fonts.iterator();
            self.current_font = it.next().?.value_ptr.*;
        }
    }

    pub fn getStyledGlyph(
        self: *FontManager,
        gme: []const u8,
        weight: FontWeight,
        slant: FontSlant,
        size: i32,
        family: FontFamily,
    ) !Glyph {
        try self.ensureFontSize(size);

        var iter = code_point.Iterator{ .bytes = gme };
        const codepoint = iter.next() orelse return error.InvalidGrapheme;

        if (codepoint.code == hyphen_codepoint) {
            return Glyph{
                .w = 0,
                .h = 0,
                .ascent = 0,
                .descent = 0,
                .is_soft_hyphen = true,
            };
        }

        const category = categoryForFamily(gme, family);
        var styled_font = self.pickFontForCharacterStyle(category, weight, slant);
        var style_set = false;
        var synthetic_bold = false;

        if (styled_font == null) {
            if (family == .monospace and weight == .Bold) {
                styled_font = self.pickFontForCharacterStyle(category, .Normal, slant);
                if (styled_font != null) {
                    synthetic_bold = true;
                }
            }

            if (styled_font == null) {
                styled_font = self.pickCategoryFallback(category);
                if (styled_font == null) styled_font = self.current_font;
                if (styled_font == null) return error.NoFontForGlyph;

                // Color emoji fonts supply their own faces. Applying a
                // synthetic bold or italic style can disable color strikes.
                if (styled_font.?.category != .emoji and
                    (weight != .Normal or slant != .Roman))
                {
                    styled_font.?.font_handle.setStyle(.{
                        .bold = weight == .Bold,
                        .italic = slant == .Italic,
                    });
                    style_set = true;
                }
            }
        }
        const font = styled_font.?;
        defer if (style_set) font.font_handle.setStyle(.{});

        // Each loaded Font owns its own glyph map, so selecting another CSS
        // family selects another cache before this per-face key is consulted.
        const key = newGlyphCacheKey(gme, weight, slant, size);
        if (font.glyphs.get(key)) |cached_glyph| {
            return cached_glyph;
        }

        font.font_handle.setSize(size);

        const sentinel_gme = try sliceToSentinelArray(self.allocator, gme);
        defer self.allocator.free(sentinel_gme);

        // SDL_ttf can reject an otherwise valid UTF-8 grapheme when a page
        // supplies a glyph that the selected platform face cannot rasterize
        // (this is common in compatibility suites, which intentionally feed
        // malformed/unsupported text).  A single rejected glyph must not
        // abort the whole layout task and leave the browser with a blank
        // frame. Keep a stable size-based advance and emit an invisible
        // fallback instead.
        var glyph_surface = font.font_handle.renderUtf8Blended(
            sentinel_gme,
            .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        ) catch |err| {
            if (err != error.TtfError and err != error.InvalidGlyphDimensions) return err;
            const fallback_width = @max(@divTrunc(size, 2), 1);
            return Glyph{
                .w = fallback_width,
                .h = @max(size, 1),
                .ascent = @max(@divTrunc(size * 3, 4), 1),
                .descent = @max(size - @divTrunc(size * 3, 4), 1),
                .pixels = null,
            };
        };
        defer glyph_surface.destroy();

        if (synthetic_bold) {
            const bold_offset = @max(1, @divTrunc(size, 24));
            const bold_surface = try sdl2.createRgbSurfaceWithFormat(
                @intCast(glyph_surface.ptr.w + bold_offset),
                @intCast(glyph_surface.ptr.h),
                .abgr8888,
            );
            try sdl2.blit(glyph_surface, null, bold_surface, null);
            var rect = sdl2.Rectangle{
                .x = bold_offset,
                .y = 0,
                .width = glyph_surface.ptr.w,
                .height = glyph_surface.ptr.h,
            };
            try sdl2.blit(glyph_surface, null, bold_surface, &rect);
            glyph_surface.destroy();
            glyph_surface = bold_surface;
        }

        const surf = glyph_surface.ptr;
        if (surf.w <= 0 or surf.h <= 0) return error.InvalidGlyphDimensions;
        const is_color_emoji = category == .emoji and font.category == .emoji;
        const ascent = font.font_handle.ascent();
        const descent = -font.font_handle.descent();
        const glyph_height = if (is_color_emoji) emojiHeightForFontSize(size) else surf.h;
        const glyph_width = if (is_color_emoji)
            emojiWidthForHeight(surf.w, surf.h, glyph_height)
        else
            surf.w;
        const pixel_data = try copySurfaceRgba(
            self.allocator,
            glyph_surface,
            glyph_width,
            glyph_height,
        );
        errdefer self.allocator.free(pixel_data);

        const new_glyph = if (!is_color_emoji) Glyph{
            .w = glyph_width,
            .h = glyph_height,
            .ascent = ascent,
            .descent = descent,
            .pixels = pixel_data,
        } else blk: {
            const emoji_ascent = @max(@divTrunc(glyph_height * 3, 4), 1);
            break :blk Glyph{
                .w = glyph_width,
                .h = glyph_height,
                .ascent = emoji_ascent,
                .descent = glyph_height - emoji_ascent,
                .pixel_mode = .color,
                .pixels = pixel_data,
            };
        };

        try font.glyphs.put(key, new_glyph);
        return new_glyph;
    }

    fn ensureFontSize(self: *FontManager, size: i32) !void {
        if (self.loaded_sizes.contains(size)) return;

        var it = self.fonts.iterator();
        while (it.next()) |entry| {
            const font = entry.value_ptr.*;
            font.font_handle.setSize(size);
        }
        try self.loaded_sizes.put(size, {});
    }

    fn pickFontForCharacterStyle(
        self: *FontManager,
        category: FontCategory,
        weight: FontWeight,
        slant: FontSlant,
    ) ?*Font {
        const key = FontKey{
            .category = category,
            .weight = weight,
            .slant = slant,
        };
        if (self.styled_fonts.get(key)) |font| {
            return font;
        }
        return null;
    }

    fn pickCategoryFallback(self: *FontManager, category: FontCategory) ?*Font {
        const fallbacks: []const FontCategory = switch (category) {
            .emoji => &.{ .emoji, .symbols, .cjk, .latin },
            .symbols => &.{ .symbols, .cjk, .latin },
            .cjk => &.{ .cjk, .latin },
            .monospace => &.{ .monospace, .latin },
            .latin => &.{.latin},
        };
        for (fallbacks) |fallback| {
            if (self.category_fonts.get(fallback)) |fallback_font| {
                return fallback_font;
            }
        }
        return null;
    }
};

fn sliceToSentinelArray(allocator: std.mem.Allocator, slice: []const u8) ![:0]const u8 {
    const len = slice.len;
    const arr = try allocator.allocSentinel(u8, len, 0);
    @memcpy(arr, slice);
    return arr;
}

test "home directory uses a non-empty HOME environment value" {
    const allocator = std.testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();

    try std.testing.expect(homeDirectory(&environ) == null);
    try environ.put("HOME", "");
    try std.testing.expect(homeDirectory(&environ) == null);
    try environ.put("HOME", "/home/zibra");
    try std.testing.expectEqualStrings("/home/zibra", homeDirectory(&environ).?);
}

pub fn getCategory(codepoint: u21) ?FontCategory {
    if (unicode_emoji.isEmojiPresentation(codepoint)) return .emoji;
    if (codepoint > 0x7F and unicode_emoji.isEmoji(codepoint)) return .symbols;
    for (unicode_ranges.cjk) |range| {
        if (codepoint >= range.start and codepoint <= range.end) return .cjk;
    }
    for (unicode_ranges.latin) |range| {
        if (codepoint >= range.start and codepoint <= range.end) return .latin;
    }
    return null;
}

/// Return whether a complete grapheme cluster requests emoji presentation.
pub fn isEmojiGrapheme(gme: []const u8) bool {
    var iter = code_point.Iterator{ .bytes = gme };
    const first = iter.next() orelse return false;
    var has_text_selector = false;
    var has_emoji_selector = false;
    var has_keycap = false;
    var has_joiner = false;
    var has_modifier = false;

    while (iter.next()) |current| {
        switch (current.code) {
            0xFE0E => has_text_selector = true,
            0xFE0F => has_emoji_selector = true,
            0x20E3 => has_keycap = true,
            0x200D => has_joiner = true,
            else => if (unicode_emoji.isEmojiModifier(current.code)) {
                has_modifier = true;
            },
        }
    }

    if (has_text_selector and !has_emoji_selector) return false;
    if (has_emoji_selector and unicode_emoji.isEmoji(first.code)) return true;
    if (has_keycap and unicode_emoji.isEmoji(first.code)) return true;
    if (has_modifier and unicode_emoji.isEmojiModifierBase(first.code)) return true;
    if (has_joiner and unicode_emoji.isExtendedPictographic(first.code)) return true;
    return unicode_emoji.isEmojiPresentation(first.code);
}

/// Choose one font for an entire grapheme cluster. Unknown scripts fall back
/// to the Latin face so SDL_ttf can render its normal missing-glyph marker.
pub fn getGraphemeCategory(gme: []const u8) FontCategory {
    if (isEmojiGrapheme(gme)) return .emoji;
    var iter = code_point.Iterator{ .bytes = gme };
    const first = iter.next() orelse return .latin;
    while (iter.next()) |current| {
        if (current.code == 0xFE0E and unicode_emoji.isEmoji(first.code)) {
            return .symbols;
        }
    }
    return getCategory(first.code) orelse .latin;
}

/// Apply a CSS family preference without sacrificing the specialized fallback
/// faces required for CJK, symbols, and emoji.
pub fn categoryForFamily(gme: []const u8, family: FontFamily) FontCategory {
    const category = getGraphemeCategory(gme);
    return if (family == .monospace and category == .latin) .monospace else category;
}

fn unquoteCssFamily(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len >= 2 and
        ((trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'') or
            (trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"')))
    {
        return std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
    }
    return trimmed;
}

fn isMonospaceFamily(name: []const u8) bool {
    const aliases = [_][]const u8{
        "monospace",
        "ui-monospace",
        "courier",
        "courier new",
        "andale mono",
        "dejavu sans mono",
        "dejavusansmono",
    };
    for (aliases) |alias| {
        if (std.ascii.eqlIgnoreCase(name, alias)) return true;
    }
    return false;
}

fn isProportionalFamily(name: []const u8) bool {
    const aliases = [_][]const u8{
        "sans-serif",
        "serif",
        "system-ui",
        "ui-sans-serif",
        "ui-serif",
        "cursive",
        "fantasy",
        "arial",
        "helvetica",
        "noto sans",
        "notosans-regular",
    };
    for (aliases) |alias| {
        if (std.ascii.eqlIgnoreCase(name, alias)) return true;
    }
    return false;
}

/// Resolve the first supported entry in a CSS font-family fallback list.
/// Unsupported named fonts are skipped; an entirely unsupported list falls
/// back to Zibra's normal proportional system face.
pub fn familyFromCss(value: []const u8) FontFamily {
    var families = std.mem.splitScalar(u8, value, ',');
    while (families.next()) |raw_family| {
        const family = unquoteCssFamily(raw_family);
        if (isMonospaceFamily(family)) return .monospace;
        if (isProportionalFamily(family)) return .proportional;
    }
    return .proportional;
}

fn hashCombine(seed: u64, value: u64) u64 {
    // A common hash combine (borrowed from boost::hash_combine)
    return seed ^ (value +% 0x9e3779b97f4a7c15 +% (seed << 6) +% (seed >> 2));
}

fn newGlyphCacheKey(gme: []const u8, weight: FontWeight, slant: FontSlant, size: i32) u64 {
    // Prepare style bits: bit 0 for Bold, bit 1 for Italic.
    var bits: u8 = 0;
    if (weight == .Bold) bits |= 1;
    if (slant == .Italic) bits |= 2;

    const grapheme_hash = std.hash.Fnv1a_64.hash(gme);

    // Combine the hashed grapheme, the size, and the style bits.
    var key = hashCombine(grapheme_hash, @as(u64, @intCast(size)));
    key = hashCombine(key, @as(u64, bits));
    return key;
}

test "emoji grapheme classification covers presentation sequences" {
    const emoji_graphemes = [_][]const u8{
        "😀",
        "🚀",
        "🇺🇸",
        "👍🏽",
        "👨‍👩‍👧‍👦",
        "❤️",
        "☀️",
    };
    for (emoji_graphemes) |gme| {
        try std.testing.expect(isEmojiGrapheme(gme));
        try std.testing.expectEqual(FontCategory.emoji, getGraphemeCategory(gme));
    }

    try std.testing.expect(!isEmojiGrapheme("A"));
    try std.testing.expect(!isEmojiGrapheme("☀"));
}

test "grapheme font category preserves text and CJK fallbacks" {
    try std.testing.expectEqual(FontCategory.latin, getGraphemeCategory("A"));
    try std.testing.expectEqual(FontCategory.cjk, getGraphemeCategory("中"));
    try std.testing.expectEqual(FontCategory.symbols, getGraphemeCategory("☀"));
    try std.testing.expectEqual(FontCategory.symbols, getGraphemeCategory("😀︎"));
}

test "CSS font families select monospace without replacing Unicode fallbacks" {
    try std.testing.expectEqual(FontFamily.monospace, familyFromCss("Courier"));
    try std.testing.expectEqual(FontFamily.monospace, familyFromCss("'Courier New', serif"));
    try std.testing.expectEqual(FontFamily.monospace, familyFromCss("Missing Face, monospace"));
    try std.testing.expectEqual(FontFamily.proportional, familyFromCss("Arial, monospace"));
    try std.testing.expectEqual(FontFamily.proportional, familyFromCss("Missing Face"));

    try std.testing.expectEqual(FontCategory.monospace, categoryForFamily("A", .monospace));
    try std.testing.expectEqual(FontCategory.latin, categoryForFamily("A", .proportional));
    try std.testing.expectEqual(FontCategory.cjk, categoryForFamily("中", .monospace));
    try std.testing.expectEqual(FontCategory.emoji, categoryForFamily("😀", .monospace));
}

test "emoji bitmap scaling preserves aspect ratio and validates dimensions" {
    try std.testing.expectEqual(@as(i32, 12), emojiHeightForFontSize(12));
    try std.testing.expectEqual(@as(i32, 0), emojiHeightForFontSize(0));
    try std.testing.expectEqual(@as(i32, 16), emojiWidthForHeight(128, 128, 16));
    try std.testing.expectEqual(@as(i32, 32), emojiWidthForHeight(256, 128, 16));
    try std.testing.expectEqual(@as(i32, 8), emojiWidthForHeight(64, 128, 16));
    try std.testing.expectEqual(@as(i32, 0), emojiWidthForHeight(0, 128, 16));
}
